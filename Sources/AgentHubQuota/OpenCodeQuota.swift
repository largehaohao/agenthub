import Foundation

/// Decodes the OpenCode Go usage response.
///
/// Live shape from `https://opencode.ai/zen/go/v1/usage`:
/// ```
/// {"usage":{"rolling":{"status":"ok","percent":0,"resetsAt":"..."},
///           "weekly":{...},"monthly":{...}}}
/// ```
public struct OpenCodeGoQuotaDecoder: Sendable {
    public static let source = "opencode-go"

    /// Window keys the endpoint reports, with the durations they represent.
    /// `rolling` resets roughly four hours out on a five-hour cadence, matching
    /// the session window the other providers expose.
    static let knownWindows: [(key: String, label: String, duration: TimeInterval)] = [
        ("rolling", "Session", 5 * 3_600),
        ("weekly", "Weekly", 7 * 24 * 3_600),
        ("monthly", "Monthly", 30 * 24 * 3_600),
    ]

    private let accountID: String

    public init(accountID: String) {
        self.accountID = accountID
    }

    /// A malformed payload yields no windows rather than throwing: quota is
    /// supplementary and must not fail the adapter.
    public func decode(_ data: Data, now: Date) throws -> [QuotaWindow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = root["usage"] as? [String: Any] else {
            return []
        }

        return Self.knownWindows.compactMap { known in
            // Only an "ok" window carries a usable number. Anything else means
            // unknown, and 0% would read as "plenty left".
            guard let entry = usage[known.key] as? [String: Any],
                  (entry["status"] as? String) == "ok",
                  let percent = Self.double(entry["percent"]),
                  let resetsAt = Self.date(entry["resetsAt"]) else {
                return nil
            }

            return try? QuotaWindow(
                provider: .openCode,
                accountID: accountID,
                windowID: known.key,
                label: known.label,
                usedPercent: percent,
                windowDuration: known.duration,
                resetsAt: resetsAt,
                fetchedAt: now,
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
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// Reads the OpenCode Go subscription key from the local CLI's auth file.
///
/// The key is returned for a single request and never stored by AgentHub: it is
/// not written to SQLite, the Keychain, or any log, mirroring the rule already
/// applied to Cursor tokens.
public struct OpenCodeGoKeyReader: Sendable {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func standard() -> OpenCodeGoKeyReader {
        OpenCodeGoKeyReader(
            fileURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share/opencode/auth.json")
        )
    }

    /// Returns nil when the CLI is not signed in to OpenCode Go.
    public func readKey() -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root["opencode-go"] as? [String: Any],
              let key = entry["key"] as? String,
              !key.isEmpty else {
            return nil
        }
        return key
    }
}

/// Rate-limits calls to the OpenCode Go usage API.
///
/// `reconcile()` runs on every session change, hook delivery, and quota tick,
/// while subscription usage moves slowly. Without this the adapter would call an
/// external service many times a minute. A failed refresh keeps the previous
/// reading rather than blanking the strip, per §11 of the design.
public actor OpenCodeGoQuotaCache {
    /// Quota windows are only excluded from recommendations after 15 minutes,
    /// so refreshing faster than that buys nothing.
    public static let defaultInterval: TimeInterval = 900

    private let minimumInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let fetch: @Sendable () async -> [QuotaWindow]

    private var cached: [QuotaWindow] = []
    private var lastAttempt: Date?

    public init(
        minimumInterval: TimeInterval = OpenCodeGoQuotaCache.defaultInterval,
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
        // An empty result means the call failed or the CLI is signed out; the
        // last real reading is more useful than nothing.
        if !fetched.isEmpty {
            cached = fetched
        }
        return cached
    }
}

/// Fetches OpenCode Go usage over HTTPS.
public struct OpenCodeGoQuotaClient: Sendable {
    public static let endpoint = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    private let session: URLSession
    private let keyReader: OpenCodeGoKeyReader
    private let decoder: OpenCodeGoQuotaDecoder
    private let now: @Sendable () -> Date

    public init(
        session: URLSession = .shared,
        keyReader: OpenCodeGoKeyReader = .standard(),
        accountID: String = "go",
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.keyReader = keyReader
        self.decoder = OpenCodeGoQuotaDecoder(accountID: accountID)
        self.now = now
    }

    /// Returns no windows when the CLI is not signed in or the call fails, so a
    /// network problem degrades this one source rather than the adapter.
    public func fetch() async -> [QuotaWindow] {
        guard let key = keyReader.readKey() else { return [] }

        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 10
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200 else {
            return []
        }
        return (try? decoder.decode(data, now: now())) ?? []
    }
}
