import Foundation
import AgentHubCore

public enum ClaudeStatusLineError: Error, Equatable, Sendable {
    /// Never carries payload text, so a malformed status line cannot leak the
    /// prompt, cwd, or any token through an error description.
    case malformedPayload
}

/// One status-line observation: the quota windows Claude Code reported, plus
/// the session that reported them.
///
/// Deliberately holds no prompt, transcript path, or context-window detail —
/// only what a usage display needs.
public struct ClaudeStatusLineReport: Equatable, Sendable {
    public let sessionID: String
    public let windows: [QuotaWindow]

    public init(sessionID: String, windows: [QuotaWindow]) {
        self.sessionID = sessionID
        self.windows = windows
    }
}

/// Reads the JSON Claude Code pipes to a `statusLine` command.
///
/// This is AgentHub's own quota source: `rate_limits` carries Anthropic's real
/// `used_percentage` and `resets_at` for each window, so nothing here is
/// estimated from token counts.
public struct ClaudeStatusLineDecoder: Sendable {
    public static let maximumPayloadBytes = 256 * 1_024

    /// Window keys Claude Code reports, with the durations they represent.
    /// Order is fixed so a display never reshuffles between refreshes.
    static let knownWindows: [(key: String, label: String, duration: TimeInterval)] = [
        ("five_hour", "Session", 5 * 3_600),
        ("seven_day", "Weekly", 7 * 24 * 3_600),
    ]

    private let accountID: String

    public init(accountID: String = "default") {
        self.accountID = accountID
    }

    /// Distinguishes a status-line payload from a hook payload. Claude Code
    /// sends hooks with `hook_event_name` and status lines without it, so the
    /// two never need to be guessed apart by content.
    public static func looksLikeStatusLine(_ data: Data) -> Bool {
        guard data.count <= maximumPayloadBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return root["hook_event_name"] == nil
            && (root["rate_limits"] != nil || root["context_window"] != nil)
    }

    public func decode(_ data: Data) throws -> ClaudeStatusLineReport {
        guard data.count <= Self.maximumPayloadBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeStatusLineError.malformedPayload
        }

        let sessionID = root["session_id"] as? String ?? ""
        let limits = root["rate_limits"] as? [String: Any] ?? [:]

        // A window is emitted only when both its percentage and reset time are
        // present and valid. Absent data stays absent rather than showing 0%.
        let windows = Self.knownWindows.compactMap { known -> QuotaWindow? in
            guard let entry = limits[known.key] as? [String: Any],
                  let usedPercent = Self.double(entry["used_percentage"]),
                  let resetsAt = Self.timestamp(entry["resets_at"]) else {
                return nil
            }

            return try? QuotaWindow(
                provider: .claude,
                accountID: accountID,
                windowID: known.key,
                label: known.label,
                plan: root["plan"] as? String,
                usedPercent: usedPercent,
                windowDuration: known.duration,
                resetsAt: resetsAt,
                fetchedAt: Self.timestamp(root["observed_at"]) ?? Date(),
                source: "claude-statusline"
            )
        }

        return ClaudeStatusLineReport(sessionID: sessionID, windows: windows)
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }

    private static func timestamp(_ value: Any?) -> Date? {
        if let text = value as? String {
            // Anthropic sends fractional seconds
            // ("2026-08-12T14:50:00.458358+00:00"), which the plain parser
            // rejects. A rejected reset time dropped the whole window silently,
            // freezing usage at whatever was last read from the usage cache.
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        }
        if let seconds = double(value) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}
