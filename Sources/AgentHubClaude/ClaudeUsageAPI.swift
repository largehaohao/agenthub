import Foundation
import Security
import AgentHubCore

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

/// Claude Code's OAuth credential, read from the login Keychain.
///
/// Held in memory for the lifetime of one request. AgentHub never writes it to
/// SQLite, its own Keychain service, a log, or an IPC message, matching the rule
/// already applied to Cursor tokens.
public struct ClaudeOAuthCredential: Sendable {
    public let token: String
    public let expiresAt: Date?

    init?(json data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            return nil
        }
        self.token = token
        self.expiresAt = (oauth["expiresAt"] as? Double).map {
            Date(timeIntervalSince1970: $0 / 1_000)
        }
    }

    /// Claude Code refreshes the token in place, so an expired one means Claude
    /// Code has not run recently. Usage is then skipped rather than refreshed
    /// here, which would risk invalidating Claude Code's own session.
    public func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }
}

/// Reads Claude Code's OAuth credential from the login Keychain.
public struct ClaudeOAuthCredentialReader: Sendable {
    public static let defaultService = "Claude Code-credentials"

    private let service: String

    public init(service: String = ClaudeOAuthCredentialReader.defaultService) {
        self.service = service
    }

    /// Returns nil when Claude Code is not signed in, or when the daemon is not
    /// permitted to read the item.
    public func read() -> ClaudeOAuthCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return ClaudeOAuthCredential(json: data)
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
    private let credentials: ClaudeOAuthCredentialReader
    private let accountID: String
    private let now: @Sendable () -> Date

    public init(
        session: URLSession = .shared,
        credentials: ClaudeOAuthCredentialReader = ClaudeOAuthCredentialReader(),
        accountID: String = "default",
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.credentials = credentials
        self.accountID = accountID
        self.now = now
    }

    /// Returns no windows when signed out, when the token has expired, or when
    /// the call fails, so a network problem degrades this one source rather than
    /// the Claude adapter.
    public func fetch() async -> [QuotaWindow] {
        guard let credential = credentials.read(), !credential.isExpired(now: now()) else {
            return []
        }

        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 10
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200 else {
            return []
        }
        return (try? ClaudeUsageWindows.decode(
            data,
            accountID: accountID,
            fetchedAt: now(),
            source: Self.source
        )) ?? []
    }
}

/// Rate-limits calls to the usage API.
///
/// `reconcile()` runs on every hook delivery and session change, while
/// subscription usage moves slowly. A failed refresh keeps the previous reading
/// rather than blanking the strip.
public actor ClaudeUsageCache {
    public static let defaultInterval: TimeInterval = 900

    private let minimumInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let fetch: @Sendable () async -> [QuotaWindow]

    private var cached: [QuotaWindow] = []
    private var lastAttempt: Date?

    public init(
        minimumInterval: TimeInterval = ClaudeUsageCache.defaultInterval,
        now: @escaping @Sendable () -> Date = { Date() },
        fetch: @escaping @Sendable () async -> [QuotaWindow]
    ) {
        self.minimumInterval = minimumInterval
        self.now = now
        self.fetch = fetch
    }

    /// - Parameter force: bypasses the interval for an explicit user refresh.
    public func windows(force: Bool = false) async -> [QuotaWindow] {
        if !force, let lastAttempt,
           now().timeIntervalSince(lastAttempt) < minimumInterval {
            return cached
        }
        lastAttempt = now()
        let fetched = await fetch()
        if !fetched.isEmpty {
            cached = fetched
        }
        return cached
    }
}
