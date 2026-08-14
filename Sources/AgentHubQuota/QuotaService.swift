import Foundation

/// One provider's contribution to the panel.
public struct QuotaSource: Sendable {
    public let provider: Provider
    public let fetch: @Sendable () async -> [QuotaWindow]
    /// Why this provider has nothing to report, asked only when it reports
    /// nothing. A silent gap looks like a bug; the reason is usually a sign-in
    /// the user can fix.
    public let notice: @Sendable () async -> String?

    public init(
        provider: Provider,
        fetch: @escaping @Sendable () async -> [QuotaWindow],
        notice: @escaping @Sendable () async -> String? = { nil }
    ) {
        self.provider = provider
        self.fetch = fetch
        self.notice = notice
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
    /// How soon a provider that has reported nothing is tried again.
    ///
    /// The long interval protects readings we already have; a provider with no
    /// reading has nothing to protect, and its first number is the one the user
    /// is waiting for. Cursor in particular fetches on its own schedule, so its
    /// first result routinely lands just after the panel's first refresh.
    public static let emptyRetryInterval: TimeInterval = 60

    private let sources: [QuotaSource]
    private let minimumInterval: TimeInterval
    private let now: @Sendable () -> Date

    private var cached: [Provider: [QuotaWindow]] = [:]
    private var notices: [Provider: String] = [:]
    /// Tracked per provider: one slow or failing source must not hold the
    /// others to its schedule.
    private var lastAttempt: [Provider: Date] = [:]

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
        let now = self.now()
        let due = sources.filter { force || isDue($0.provider, now: now) }
        guard !due.isEmpty else { return flattened() }
        for source in due { lastAttempt[source.provider] = now }

        // Providers are fetched together; one slow source should not serialise
        // behind another.
        await withTaskGroup(of: (Provider, [QuotaWindow], String?).self) { group in
            for source in due {
                group.addTask {
                    let fetched = await source.fetch()
                    // Only a provider with nothing to show owes an explanation.
                    return (source.provider, fetched, fetched.isEmpty ? await source.notice() : nil)
                }
            }
            for await (provider, fetched, notice) in group {
                if !fetched.isEmpty { cached[provider] = fetched }
                notices[provider] = notice
            }
        }
        return flattened()
    }

    /// Explanations gathered by the last refresh, keyed by provider.
    public func currentNotices() -> [Provider: String] {
        // A provider holding a previous reading is showing numbers, so any
        // explanation would contradict what is on screen.
        notices.filter { cached[$0.key]?.isEmpty ?? true }
    }

    private func isDue(_ provider: Provider, now: Date) -> Bool {
        guard let last = lastAttempt[provider] else { return true }
        let interval = (cached[provider]?.isEmpty ?? true)
            ? Self.emptyRetryInterval
            : minimumInterval
        return now.timeIntervalSince(last) >= interval
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
            .init(
                provider: .claude,
                fetch: { await claude.fetch() },
                notice: { await claude.notice() }
            ),
            .init(provider: .codex, fetch: { await codex.fetch() }),
            // Cursor polls itself once authorised; this reads what it holds.
            .init(
                provider: .cursor,
                fetch: { await cursor.currentWindows() },
                notice: {
                    guard await cursor.isAuthorized else {
                        return "Cursor usage is off — turn it on in Settings"
                    }
                    // Cursor polls on its own schedule, so the first reading can
                    // arrive after the panel's. Saying so beats a blank gap that
                    // looks like a failure.
                    return await cursor.lastErrorMessage ?? "Cursor usage has not arrived yet"
                }
            ),
            .init(provider: .openCode, fetch: { await openCode.fetch() }),
        ])
    }
}
