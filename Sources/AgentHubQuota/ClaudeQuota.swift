import Foundation
import Security

/// Decodes Anthropic's usage payload.
///
/// The same shape is served by `GET /api/oauth/usage` and cached by Claude Code
/// in `~/.claude.json`, so both sources share this decoder.
public enum ClaudeUsageWindows {
    /// Window keys with the durations they represent. Other keys are
    /// product-specific windows whose duration is not documented; they are
    /// ignored rather than given an invented one.
    static let knownWindows: [(key: String, label: String, duration: TimeInterval)] = [
        ("five_hour", "Session", 5 * 3_600),
        ("seven_day", "Weekly", 7 * 24 * 3_600),
    ]

    /// Decodes a utilization dictionary. A malformed payload yields no windows
    /// rather than throwing: usage is supplementary and must not fail a refresh.
    public static func decode(
        _ data: Data,
        accountID: String,
        fetchedAt: Date,
        source: String
    ) throws -> [QuotaWindow] {
        guard let utilization = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            return []
        }
        return decode(
            utilization: utilization,
            accountID: accountID,
            fetchedAt: fetchedAt,
            source: source
        )
    }

    static func decode(
        utilization: [String: Any],
        accountID: String,
        fetchedAt: Date,
        source: String
    ) -> [QuotaWindow] {
        knownWindows.compactMap { known in
            // A window the account does not have reports null; showing 0% would
            // read as "plenty left" rather than "unknown".
            guard let entry = utilization[known.key] as? [String: Any],
                  let percent = double(entry["utilization"]),
                  let resetsAt = date(entry["resets_at"]) else {
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
                source: source
            )
        }
    }

    static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        // Anthropic sends fractional seconds; the plain parser rejects them.
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// Fetches Claude usage from Anthropic directly.
///
/// This is the authoritative source: it reports the account's current windows
/// whether or not a Claude Code session is running, unlike the status line
/// (which only reports while one renders) and the local cache in
/// `~/.claude.json` (which Claude Code writes intermittently and may remove).
public struct ClaudeUsageAPIClient: Sendable {
    public static let source = "claude-usage-api"
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let session: URLSession
    private let refresher: ClaudeTokenRefresher
    private let accountID: String
    private let now: @Sendable () -> Date

    public init(
        session: URLSession = .shared,
        refresher: ClaudeTokenRefresher = ClaudeTokenRefresher(),
        accountID: String = "default",
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.refresher = refresher
        self.accountID = accountID
        self.now = now
    }

    /// Returns no windows when signed out or when the call fails, so a network
    /// problem degrades this one source rather than the Claude adapter.
    ///
    /// An expired token is renewed rather than skipped: Claude Code's tokens
    /// last eight hours, so skipping meant Claude usage was missing for most of
    /// every day.
    public func fetch() async -> [QuotaWindow] {
        guard let token = await refresher.token() else { return [] }

        switch await request(token: token) {
        case .success(let data):
            return decode(data)
        case .unauthorized:
            // The stored token was rejected even though it had not expired by
            // the clock — revoked, or rotated behind our back. One forced
            // refresh distinguishes that from a signed-out account.
            guard let renewed = await refresher.token(force: true),
                  case .success(let data) = await request(token: renewed) else {
                return []
            }
            return decode(data)
        case .failed:
            return []
        }
    }

    /// Why Claude has no numbers, when it has none.
    public func notice() async -> String? {
        await refresher.diagnosis().panelMessage
    }

    private enum Outcome {
        case success(Data)
        case unauthorized
        case failed
    }

    private func request(token: String) async -> Outcome {
        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            return .failed
        }
        switch http.statusCode {
        case 200: return .success(data)
        case 401, 403: return .unauthorized
        default: return .failed
        }
    }

    private func decode(_ data: Data) -> [QuotaWindow] {
        (try? ClaudeUsageWindows.decode(
            data,
            accountID: accountID,
            fetchedAt: now(),
            source: Self.source
        )) ?? []
    }
}
