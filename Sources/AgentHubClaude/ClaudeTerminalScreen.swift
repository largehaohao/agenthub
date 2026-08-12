import CryptoKit
import Foundation
import AgentHubCore

/// One selectable option Claude is currently displaying.
public struct ClaudeRequestOption: Equatable, Sendable {
    public let index: Int
    public let label: String

    public init(index: Int, label: String) {
        self.index = index
        self.label = label
    }
}

/// A parsed snapshot of what a Claude pane is showing right now.
///
/// The fingerprint identifies the exact visible prompt. AgentHub re-captures and
/// re-fingerprints immediately before sending any input, so a prompt that
/// changed between the user's click and the send is never acted on.
public struct ClaudeTerminalScreen: Equatable, Sendable {
    public let fingerprint: String
    public let isIdleComposer: Bool
    public let requestOptions: [ClaudeRequestOption]

    /// Bounds hashing and scanning work regardless of scrollback size.
    static let maximumScannedBytes = 16 * 1_024

    public static func parse(_ raw: String) throws -> ClaudeTerminalScreen {
        let canonical = canonicalize(raw)
        let options = parseOptions(in: canonical)

        return ClaudeTerminalScreen(
            fingerprint: fingerprint(of: canonical),
            isIdleComposer: options.isEmpty && isIdleComposer(canonical),
            requestOptions: options
        )
    }

    /// Removes ANSI styling and normalizes whitespace so a redraw that only
    /// changes highlighting or box padding keeps the same fingerprint, while any
    /// change to the visible text changes it. Interior runs of spaces collapse
    /// because Claude pads its boxes to the current terminal width.
    static func canonicalize(_ raw: String) -> String {
        let bounded = String(raw.suffix(maximumScannedBytes))
        return stripANSI(bounded)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line
                    .split(separator: " ", omittingEmptySubsequences: true)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func stripANSI(_ text: String) -> String {
        var output = String()
        output.reserveCapacity(text.count)

        var iterator = text.makeIterator()
        var pending: Character?

        while let character = pending ?? iterator.next() {
            pending = nil
            guard character == "\u{1B}" else {
                output.append(character)
                continue
            }
            // CSI sequences end at a byte in the range @ through ~; other
            // escapes are dropped along with their single following character.
            guard let next = iterator.next() else { break }
            if next == "[" {
                while let terminator = iterator.next() {
                    if ("@"..."~").contains(terminator) { break }
                }
            }
        }
        return output
    }

    private static func fingerprint(of canonical: String) -> String {
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// An idle composer shows an empty prompt box and no pending question.
    private static func isIdleComposer(_ canonical: String) -> Bool {
        guard !canonical.contains("esc to interrupt") else { return false }

        return canonical
            .split(separator: "\n", omittingEmptySubsequences: true)
            .contains { line in
                let stripped = line
                    .replacingOccurrences(of: "│", with: "")
                    .trimmingCharacters(in: .whitespaces)
                return stripped == ">"
            }
    }

    /// Reads numbered options exactly as displayed. Labels are taken verbatim
    /// so a decision can only ever name something the user can actually see.
    private static func parseOptions(in canonical: String) -> [ClaudeRequestOption] {
        var options: [ClaudeRequestOption] = []

        for line in canonical.split(separator: "\n", omittingEmptySubsequences: true) {
            var text = line
                .replacingOccurrences(of: "│", with: " ")
                .replacingOccurrences(of: "❯", with: " ")
                .trimmingCharacters(in: .whitespaces)

            guard let separator = text.firstIndex(of: "."),
                  let index = Int(text[text.startIndex..<separator]),
                  index > 0 else { continue }

            text = String(text[text.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            // Options are numbered consecutively from 1; anything else is
            // ordinary transcript text that merely began with a number.
            guard index == options.count + 1 else { continue }
            options.append(ClaudeRequestOption(index: index, label: text))
        }
        return options
    }
}

/// Executes a request decision against a managed Claude pane, but only after
/// revalidating that the pane still belongs to the expected session and is still
/// showing the exact prompt the decision was made against.
public struct ClaudeManagedRequestExecutor: Sendable {
    public init() {}

    public func resolve(
        decision: RequestDecision,
        expectedFingerprint: String,
        runtime: ClaudeManagedRuntime,
        terminal: any ClaudeTerminalControlling
    ) async throws {
        guard try await terminal.isAlive(sessionName: runtime.sessionName) else {
            throw ClaudeTerminalError.sessionNotFound
        }

        // Re-read the pane now; the state captured when the request was raised
        // is only a hint, never the authority for sending input.
        let screen = try ClaudeTerminalScreen.parse(
            await terminal.capture(paneID: runtime.paneID)
        )
        guard screen.fingerprint == expectedFingerprint else {
            throw ClaudeTerminalError.stalePrompt
        }

        switch decision {
        case .accept:
            try await select(matching: ["yes"], screen: screen, runtime: runtime, terminal: terminal)

        case .acceptForSession:
            try await select(
                matching: ["don't ask again", "dont ask again", "yes, and"],
                screen: screen,
                runtime: runtime,
                terminal: terminal
            )

        case .decline:
            try await select(
                matching: ["no"],
                screen: screen,
                runtime: runtime,
                terminal: terminal
            )

        case .cancel:
            try await select(
                matching: ["cancel", "no"],
                screen: screen,
                runtime: runtime,
                terminal: terminal
            )

        case .choices(let labels):
            guard let label = labels.first, labels.count == 1 else {
                throw ClaudeTerminalError.stalePrompt
            }
            try await selectExact(label, screen: screen, runtime: runtime, terminal: terminal)

        case .answers(let grouped):
            guard let labels = grouped.first, grouped.count == 1, labels.count == 1,
                  let label = labels.first else {
                throw ClaudeTerminalError.stalePrompt
            }
            try await selectExact(label, screen: screen, runtime: runtime, terminal: terminal)

        case .text(let text):
            // Free text is only ever typed into an empty composer, never into a
            // pending choice where it could select an unintended option.
            guard screen.isIdleComposer else { throw ClaudeTerminalError.stalePrompt }
            try await terminal.pasteLiteral(text, paneID: runtime.paneID)
            try await terminal.submit(paneID: runtime.paneID)
        }
    }

    /// Chooses the first visible option whose label matches one of the accepted
    /// forms. Matching is case-insensitive on the visible label only.
    private func select(
        matching candidates: [String],
        screen: ClaudeTerminalScreen,
        runtime: ClaudeManagedRuntime,
        terminal: any ClaudeTerminalControlling
    ) async throws {
        for candidate in candidates {
            let match = screen.requestOptions.first { option in
                let label = option.label.lowercased()
                return label == candidate || label.contains(candidate)
            }
            if let match {
                try await send(match, runtime: runtime, terminal: terminal)
                return
            }
        }
        throw ClaudeTerminalError.stalePrompt
    }

    private func selectExact(
        _ label: String,
        screen: ClaudeTerminalScreen,
        runtime: ClaudeManagedRuntime,
        terminal: any ClaudeTerminalControlling
    ) async throws {
        guard let match = screen.requestOptions.first(where: { $0.label == label }) else {
            throw ClaudeTerminalError.stalePrompt
        }
        try await send(match, runtime: runtime, terminal: terminal)
    }

    private func send(
        _ option: ClaudeRequestOption,
        runtime: ClaudeManagedRuntime,
        terminal: any ClaudeTerminalControlling
    ) async throws {
        try await terminal.pasteLiteral(option.label, paneID: runtime.paneID)
    }
}
