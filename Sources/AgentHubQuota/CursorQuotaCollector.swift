import Foundation

public enum CursorQuotaCollectorError: Error, Equatable, Sendable {
    case notAuthorized
}

/// Polls Cursor dashboard usage after explicit authorization.
///
/// Tokens are read into memory for each refresh and are never persisted by
/// AgentHub. Revocation clears windows and stops polling.
public actor CursorQuotaCollector {
    public static let defaultPollInterval: Duration = .seconds(300)

    private let accountID: String
    private let auth: CursorQuotaAuthStore
    private let reader: CursorLoginSessionReader
    private let client: CursorQuotaClient
    private let pollInterval: Duration
    private let now: @Sendable () -> Date

    private var windows: [QuotaWindow] = []
    /// Surfaced in Settings so an authorised-but-failing state is visible
    /// instead of looking like "no usage".
    public private(set) var lastErrorMessage: String?
    private var pollTask: Task<Void, Never>?

    public init(
        accountID: String = "default",
        auth: CursorQuotaAuthStore,
        reader: CursorLoginSessionReader,
        client: CursorQuotaClient,
        pollInterval: Duration = .seconds(300),
        now: @escaping @Sendable () -> Date = { Date() },
        resumePollingOnInit: Bool = true
    ) {
        self.accountID = accountID
        self.auth = auth
        self.reader = reader
        self.client = client
        self.pollInterval = pollInterval
        self.now = now

        if resumePollingOnInit, auth.isAuthorized {
            Task { await self.startPolling() }
        }
    }

    public var isAuthorized: Bool {
        auth.isAuthorized
    }

    public func currentWindows() -> [QuotaWindow] {
        windows
    }

    public func authorize() {
        auth.authorize()
        startPolling()
    }

    public func revoke() {
        auth.revoke()
        windows = []
        lastErrorMessage = nil
        stopPolling()
    }

    @discardableResult
    public func refresh() async throws -> [QuotaWindow] {
        guard auth.isAuthorized else {
            throw CursorQuotaCollectorError.notAuthorized
        }

        let token = try reader.readAccessToken()
        do {
            let fetched = try await client.fetchWindows(token: token)
            if !fetched.isEmpty {
                windows = fetched
            }
            lastErrorMessage = nil
            return windows
        } catch {
            lastErrorMessage = "Cursor usage is temporarily unavailable."
            throw error
        }
    }

    /// The collector wired to this Mac's Cursor installation.
    public static func live(accountID: String = "default") -> CursorQuotaCollector {
        CursorQuotaCollector(
            accountID: accountID,
            auth: CursorQuotaAuthStore(),
            reader: CursorLoginSessionReader(),
            client: CursorQuotaClient(accountID: accountID),
            // cursor.com is an external API and a billing-cycle percentage moves
            // slowly, so poll well inside the staleness threshold but no faster.
            pollInterval: .seconds(900)
        )
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task {
            while !Task.isCancelled {
                guard auth.isAuthorized else { break }
                _ = try? await refresh()
                try? await Task.sleep(for: pollInterval)
            }
            pollTask = nil
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
