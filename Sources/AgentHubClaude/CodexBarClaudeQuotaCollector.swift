import Foundation
import AgentHubCore

/// Coarse quota source failures. These never carry CodexBar output, Anthropic
/// response bodies, account identifiers, or token text — only a category the
/// desktop can render and act on.
public enum ClaudeQuotaError: Error, Equatable, Sendable {
    case sourceUnavailable
    case timeout
    case authenticationRequired
    case malformedSnapshot
    case sourceFailed
}

public struct QuotaCommandResult: Equatable, Sendable {
    public let standardOutput: String
    public let standardError: String
    public let exitStatus: Int32

    public init(standardOutput: String, standardError: String, exitStatus: Int32) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitStatus = exitStatus
    }
}

/// Where the CodexBar machine-readable CLI lives. The signed app helper is
/// preferred over PATH so a shadowing binary earlier in PATH cannot silently
/// take over the quota source.
public struct CodexBarLocation: Equatable, Sendable {
    public static let appHelperPath =
        "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI"

    public let executablePath: String?

    public init(executablePath: String?) {
        self.executablePath = executablePath
    }

    public static func discover(
        isExecutable: (String) -> Bool,
        pathEnvironment: String
    ) -> CodexBarLocation {
        if isExecutable(appHelperPath) {
            return CodexBarLocation(executablePath: appHelperPath)
        }

        for directory in pathEnvironment.split(separator: ":") {
            let candidate = "\(directory)/codexbar"
            if isExecutable(candidate) {
                return CodexBarLocation(executablePath: candidate)
            }
        }

        return CodexBarLocation(executablePath: nil)
    }

    public static func discover(
        fileManager: FileManager = .default,
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"]
    ) -> CodexBarLocation {
        discover(
            isExecutable: { fileManager.isExecutableFile(atPath: $0) },
            pathEnvironment: pathEnvironment ?? ""
        )
    }
}

public struct ClaudeQuotaSnapshot: Equatable, Sendable {
    public let executablePath: String
    public let windows: [QuotaWindow]
    /// True when the source reported a partial failure or when some windows
    /// failed validation. Callers may show what survived, clearly marked.
    public let isPartial: Bool

    public init(executablePath: String, windows: [QuotaWindow], isPartial: Bool) {
        self.executablePath = executablePath
        self.windows = windows
        self.isPartial = isPartial
    }
}

public protocol ClaudeQuotaCollecting: Sendable {
    func collect() async throws -> ClaudeQuotaSnapshot
}

/// Reads Claude subscription usage from CodexBar's JSON CLI. Only machine
/// readable output is ever consumed; the human-readable cards and progress
/// bars are never parsed, so a cosmetic CodexBar change cannot corrupt data.
public struct CodexBarClaudeQuotaCollector: ClaudeQuotaCollecting {
    public static let maximumOutputBytes = 1_024 * 1_024

    private let location: CodexBarLocation
    private let run: @Sendable (ClaudeCommand) async throws -> QuotaCommandResult
    private let now: @Sendable () -> Date

    public init(
        location: CodexBarLocation,
        run: @escaping @Sendable (ClaudeCommand) async throws -> QuotaCommandResult,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.location = location
        self.run = run
        self.now = now
    }

    public func collect() async throws -> ClaudeQuotaSnapshot {
        guard let executable = location.executablePath else {
            throw ClaudeQuotaError.sourceUnavailable
        }

        let command = ClaudeCommand(
            executable: executable,
            arguments: [
                "usage",
                "--provider", "claude",
                "--source", "auto",
                "--format", "json",
                "--json-only",
                "--timeout", "10",
            ]
        )

        let result: QuotaCommandResult
        do {
            result = try await run(command)
        } catch let error as ClaudeQuotaError {
            throw error
        } catch {
            throw ClaudeQuotaError.sourceFailed
        }

        guard result.exitStatus == 0 else {
            // stderr is inspected only to pick a category; its text is discarded.
            throw Self.category(forStandardError: result.standardError)
        }
        guard result.standardOutput.utf8.count <= Self.maximumOutputBytes else {
            throw ClaudeQuotaError.malformedSnapshot
        }

        return try parse(result.standardOutput, executablePath: executable)
    }

    private static func category(forStandardError text: String) -> ClaudeQuotaError {
        let lowercased = text.lowercased()
        if lowercased.contains("auth") || lowercased.contains("token")
            || lowercased.contains("login") || lowercased.contains("unauthorized") {
            return .authenticationRequired
        }
        if lowercased.contains("timeout") || lowercased.contains("timed out") {
            return .timeout
        }
        return .sourceFailed
    }

    private func parse(
        _ output: String,
        executablePath: String
    ) throws -> ClaudeQuotaSnapshot {
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeQuotaError.malformedSnapshot
        }

        // Claude CLI, Desktop, and claude.ai share one account allowance, so a
        // snapshot for any other provider must never be mapped onto Claude.
        guard root["provider"] as? String == "claude" else {
            throw ClaudeQuotaError.malformedSnapshot
        }

        let identity = root["identity"] as? [String: Any]
        guard let account = identity?["account"] as? String, !account.isEmpty else {
            throw ClaudeQuotaError.malformedSnapshot
        }
        let plan = identity?["plan"] as? String

        let fetchedAt = Self.timestamp(root["fetched_at"]) ?? now()

        let usage = root["usage"] as? [String: Any] ?? [:]
        var entries: [[String: Any]] = []
        for key in ["primary", "secondary", "tertiary"] {
            if let entry = usage[key] as? [String: Any] { entries.append(entry) }
        }
        entries.append(contentsOf: (usage["details"] as? [[String: Any]]) ?? [])

        var windows: [QuotaWindow] = []
        var droppedWindow = false
        for entry in entries {
            if let window = window(
                from: entry,
                account: account,
                plan: plan,
                fetchedAt: fetchedAt
            ) {
                windows.append(window)
            } else {
                droppedWindow = true
            }
        }

        guard !windows.isEmpty else { throw ClaudeQuotaError.malformedSnapshot }

        let reportedPartial = root["partial_failure"] != nil
        return ClaudeQuotaSnapshot(
            executablePath: executablePath,
            windows: windows,
            isPartial: reportedPartial || droppedWindow
        )
    }

    /// Builds one window, returning nil when the entry is unusable. A single
    /// bad window degrades to a partial snapshot rather than discarding the
    /// windows that are valid.
    private func window(
        from entry: [String: Any],
        account: String,
        plan: String?,
        fetchedAt: Date
    ) -> QuotaWindow? {
        guard let usedPercent = Self.double(entry["used_percent"]),
              let duration = Self.double(entry["window_seconds"]),
              let resetsAt = Self.timestamp(entry["resets_at"]) else {
            return nil
        }

        return try? QuotaWindow(
            provider: .claude,
            accountID: account,
            windowID: entry["id"] as? String,
            label: entry["label"] as? String,
            plan: plan,
            usedPercent: usedPercent,
            windowDuration: duration,
            resetsAt: resetsAt,
            fetchedAt: fetchedAt,
            source: "codexbar"
        )
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }

    private static func timestamp(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }
}
