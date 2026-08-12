import Foundation
import AgentHubCore

/// Reads Claude Code's own usage cache from `~/.claude.json`.
///
/// This is a more reliable quota source than the status line: Claude Code
/// refreshes `cachedUsageUtilization` on its own schedule, so a window is still
/// reported when no session is rendering a status line, and `fetchedAtMs`
/// records when the number was actually observed rather than when AgentHub
/// happened to read it.
///
/// Only usage numbers are lifted out. The same file holds the OAuth account,
/// project history, and feature flags; none of it is read, and no credential is
/// ever needed because this is a local file rather than an API call.
public struct ClaudeUsageCacheReader: Sendable {
    /// Window keys Claude Code reports, with the durations they represent.
    /// Other keys (per-model or product-specific windows) are ignored rather
    /// than guessed at, so a window never gets an invented duration.
    static let knownWindows: [(key: String, label: String, duration: TimeInterval)] = [
        ("five_hour", "Session", 5 * 3_600),
        ("seven_day", "Weekly", 7 * 24 * 3_600),
    ]

    public static let source = "claude-usage-cache"

    private let fileURL: URL
    private let accountID: String

    public init(fileURL: URL, accountID: String = "default") {
        self.fileURL = fileURL
        self.accountID = accountID
    }

    /// The user's file, when one exists.
    public static func standard(accountID: String = "default") -> ClaudeUsageCacheReader {
        ClaudeUsageCacheReader(
            fileURL: FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent(".claude.json"),
            accountID: accountID
        )
    }

    /// Returns the windows currently cached, or none at all.
    ///
    /// A missing or malformed file is not an error: this source is
    /// supplementary, and failing here must not take down the Claude adapter.
    public func read() throws -> [QuotaWindow] {
        guard let data = try? Data(contentsOf: fileURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = root["cachedUsageUtilization"] as? [String: Any],
              let utilization = cache["utilization"] as? [String: Any] else {
            return []
        }

        let fetchedAt = (cache["fetchedAtMs"] as? Double)
            .map { Date(timeIntervalSince1970: $0 / 1_000) } ?? Date()

        return Self.knownWindows.compactMap { known in
            // A window the account does not have reports null; showing 0% would
            // read as "plenty left" rather than "unknown".
            guard let entry = utilization[known.key] as? [String: Any],
                  let percent = Self.double(entry["utilization"]),
                  let resetsAt = Self.date(entry["resets_at"]) else {
                return nil
            }

            return try? QuotaWindow(
                provider: .claude,
                accountID: accountID,
                windowID: known.key,
                label: known.label,
                usedPercent: percent,
                windowDuration: known.duration,
                resetsAt: resetsAt,
                fetchedAt: fetchedAt,
                source: Self.source
            )
        }
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        // Claude writes fractional seconds; the plain parser rejects them.
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
