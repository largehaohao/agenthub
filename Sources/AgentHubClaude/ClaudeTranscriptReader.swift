import Foundation
import AgentHubCore

/// Coarse transcript failures. They never carry record bodies, so an unreadable
/// or malformed transcript cannot leak conversation content through an error.
public enum ClaudeTranscriptError: Error, Equatable, Sendable {
    case outsideClaudeRoot
    case unreadableTranscript
}

public protocol ClaudeTranscriptReading: Sendable {
    func recentTurns(path: String, limit: Int) throws -> [VisibleTurn]
}

/// Reads a bounded window of visible turns from a Claude JSONL transcript.
///
/// Only user and assistant text blocks are surfaced. Thinking blocks, tool
/// inputs, tool results, and unknown record types are ignored, so AgentHub never
/// mirrors reasoning or command payloads into its own storage.
public struct ClaudeTranscriptReader: ClaudeTranscriptReading {
    /// Matches the handoff bound in the approved design.
    public static let maximumTurns = 20
    /// A single record larger than this is treated as untrustworthy and skipped.
    public static let maximumRecordBytes = 256 * 1_024

    private let claudeRoot: URL

    public init(claudeRoot: URL) {
        self.claudeRoot = claudeRoot
    }

    public func recentTurns(path: String, limit: Int) throws -> [VisibleTurn] {
        guard limit > 0 else { return [] }
        let url = try validatedURL(for: path)

        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            throw ClaudeTranscriptError.unreadableTranscript
        }

        var turns: [VisibleTurn] = []
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.utf8.count <= Self.maximumRecordBytes else { continue }
            guard let turn = visibleTurn(from: Data(line.utf8)) else { continue }
            turns.append(turn)
        }

        return Array(turns.suffix(min(limit, Self.maximumTurns)))
    }

    /// Requires the resolved file to live under the configured Claude root.
    /// Both the path and its symlink target are resolved first, so neither
    /// `../` traversal nor a symlink planted inside the root can escape it.
    private func validatedURL(for path: String) throws -> URL {
        let resolvedRoot = claudeRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        let rootComponents = resolvedRoot.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count > rootComponents.count,
              Array(candidateComponents.prefix(rootComponents.count)) == rootComponents else {
            throw ClaudeTranscriptError.outsideClaudeRoot
        }
        return candidate
    }

    private func visibleTurn(from data: Data) -> VisibleTurn? {
        guard let record = try? JSONDecoder().decode(ClaudeJSONValue.self, from: data),
              let object = record.objectValue,
              let type = object["type"]?.stringValue,
              type == "user" || type == "assistant",
              let message = object["message"]?.objectValue,
              let role = message["role"]?.stringValue else { return nil }

        let text = visibleText(in: message["content"])
        guard !text.isEmpty else { return nil }

        let id = object["uuid"]?.stringValue ?? UUID().uuidString
        return VisibleTurn(
            id: id,
            role: role,
            text: text,
            createdAt: timestamp(object["timestamp"]?.stringValue)
        )
    }

    /// Concatenates only `text` blocks. A plain string content field is also
    /// accepted because older transcripts use that shape.
    private func visibleText(in content: ClaudeJSONValue?) -> String {
        if let plain = content?.stringValue { return plain }

        guard let blocks = content?.arrayValue else { return "" }
        return blocks
            .compactMap { block -> String? in
                guard let object = block.objectValue,
                      object["type"]?.stringValue == "text" else { return nil }
                return object["text"]?.stringValue
            }
            .joined(separator: "\n")
    }

    private func timestamp(_ value: String?) -> Date {
        guard let value else { return Date(timeIntervalSince1970: 0) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) ?? Date(timeIntervalSince1970: 0)
    }
}
