import Foundation

/// One provider's contribution to the panel.
public struct QuotaSource: Sendable {
    public let provider: Provider
    public let fetch: @Sendable () async -> [QuotaWindow]

    public init(provider: Provider, fetch: @escaping @Sendable () async -> [QuotaWindow]) {
        self.provider = provider
        self.fetch = fetch
    }
}

/// Collects every provider's usage behind one rate limit.
///
/// Sources are independent: a provider that is signed out or unreachable
/// returns no windows and the others are unaffected. An empty result never
/// replaces a previous reading, so a transient failure leaves the last real
/// numbers on screen rather than blanking the panel.
public actor QuotaService {
    /// Quota windows are only considered stale after fifteen minutes, so
    /// refreshing faster than that buys nothing and costs four API calls.
    public static let defaultInterval: TimeInterval = 900

    private let sources: [QuotaSource]
    private let minimumInterval: TimeInterval
    private let now: @Sendable () -> Date

    private var cached: [Provider: [QuotaWindow]] = [:]
    private var lastAttempt: Date?

    public init(
        sources: [QuotaSource],
        minimumInterval: TimeInterval = QuotaService.defaultInterval,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sources = sources
        self.minimumInterval = minimumInterval
        self.now = now
    }

    /// - Parameter force: bypasses the interval for an explicit user refresh,
    ///   so the refresh button is never a no-op.
    public func windows(force: Bool = false) async -> [QuotaWindow] {
        if !force, let lastAttempt,
           now().timeIntervalSince(lastAttempt) < minimumInterval {
            return flattened()
        }
        lastAttempt = now()

        // Providers are fetched together; one slow source should not serialise
        // behind another.
        await withTaskGroup(of: (Provider, [QuotaWindow]).self) { group in
            for source in sources {
                group.addTask { (source.provider, await source.fetch()) }
            }
            for await (provider, fetched) in group where !fetched.isEmpty {
                cached[provider] = fetched
            }
        }
        return flattened()
    }

    private func flattened() -> [QuotaWindow] {
        cached.values.flatMap { $0 }
    }

    /// The four real providers, wired to this Mac.
    public static func live() -> QuotaService {
        let claude = ClaudeUsageAPIClient()
        let codex = CodexQuotaClient()
        let cursor = CursorQuotaCollector.live()
        let openCode = OpenCodeGoQuotaClient()
        return QuotaService(sources: [
            .init(provider: .claude) { await claude.fetch() },
            .init(provider: .codex) { await codex.fetch() },
            // Cursor polls itself once authorised; this reads what it holds.
            .init(provider: .cursor) { await cursor.currentWindows() },
            .init(provider: .openCode) { await openCode.fetch() },
        ])
    }
}
