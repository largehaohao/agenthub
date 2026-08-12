import Foundation
import XCTest
import AgentHubCore
import AgentHubPersistence
import AgentHubTestSupport
@testable import AgentHubDaemon

final class CoordinatorTests: XCTestCase {
    func testReconcileRunsBeforeRecoveredStateIsPublished() async throws {
        let store = try makeCoordinatorStore()
        let pending = PendingRequest.fixture(state: .pending)
        try await store.apply(.requestUpserted(pending))
        let adapter = TestAdapter()
        await adapter.setSnapshot(AdapterSnapshot(
            sessions: [.fixture()],
            nodes: [],
            requests: [.fixture(state: .resolved)],
            quotas: []
        ))
        let coordinator = Coordinator(store: store, adapters: [.codex: adapter])

        try await coordinator.start()

        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.requests[pending.id]?.state, .resolved)
        await coordinator.stop()
    }

    /// Quota was only ever fetched during start/launch reconcile, so numbers sat
    /// hours stale with no way to update them.
    func testRefreshQuotasReconcilesAdaptersAndUpdatesWindows() async throws {
        let store = try makeCoordinatorStore()
        let adapter = TestAdapter()
        await adapter.setSnapshot(AdapterSnapshot(
            sessions: [], nodes: [], requests: [], quotas: []
        ))
        let coordinator = Coordinator(store: store, adapters: [.codex: adapter])
        try await coordinator.start()
        let before = await adapter.reconcileCount

        let fresh = try QuotaWindow(
            provider: .codex,
            accountID: "default",
            windowID: "primary",
            usedPercent: 98,
            windowDuration: 604_800,
            resetsAt: Date(timeIntervalSince1970: 1_787_012_257),
            fetchedAt: Date(),
            source: "codex-app-server"
        )
        await adapter.setSnapshot(AdapterSnapshot(
            sessions: [], nodes: [], requests: [], quotas: [fresh]
        ))

        try await coordinator.refreshQuotas()

        let after = await adapter.reconcileCount
        XCTAssertGreaterThan(after, before, "refresh must re-query the adapter")
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.quotas[fresh.id]?.usedPercent, 98)
        await coordinator.stop()
    }

    /// A window's `id` embeds its `windowID`, so when a provider starts naming a
    /// window that was previously unnamed the old row would otherwise linger
    /// forever beside the new one and double-count in the strip.
    func testRefreshQuotasDropsProviderWindowsNoLongerReported() async throws {
        let store = try makeCoordinatorStore()
        let stale = try QuotaWindow(
            provider: .codex,
            accountID: "default",
            usedPercent: 46,
            windowDuration: 604_800,
            resetsAt: Date(timeIntervalSince1970: 1_787_012_257),
            fetchedAt: Date(timeIntervalSince1970: 1_000),
            source: "codex-app-server"
        )
        try await store.apply(.quotaUpserted(stale))

        let adapter = TestAdapter()
        let fresh = try QuotaWindow(
            provider: .codex,
            accountID: "default",
            windowID: "primary",
            usedPercent: 98,
            windowDuration: 604_800,
            resetsAt: Date(timeIntervalSince1970: 1_787_012_257),
            fetchedAt: Date(),
            source: "codex-app-server"
        )
        await adapter.setSnapshot(AdapterSnapshot(
            sessions: [], nodes: [], requests: [], quotas: [fresh]
        ))
        let coordinator = Coordinator(store: store, adapters: [.codex: adapter])
        try await coordinator.start()

        try await coordinator.refreshQuotas()

        let snapshot = await coordinator.snapshot()
        XCTAssertNil(snapshot.quotas[stale.id], "superseded window must be dropped")
        XCTAssertEqual(snapshot.quotas[fresh.id]?.usedPercent, 98)
        XCTAssertEqual(snapshot.quotas.count, 1)
        await coordinator.stop()
    }

    /// A provider reporting no windows must not wipe another provider's rows.
    func testRefreshQuotasKeepsOtherProvidersWindows() async throws {
        let store = try makeCoordinatorStore()
        let claude = try QuotaWindow(
            provider: .claude,
            accountID: "default",
            windowID: "five_hour",
            usedPercent: 55,
            windowDuration: 18_000,
            resetsAt: Date(timeIntervalSince1970: 1_787_000_000),
            fetchedAt: Date(),
            source: "claude-statusline"
        )
        try await store.apply(.quotaUpserted(claude))

        let adapter = TestAdapter()  // provider .codex, reports nothing
        await adapter.setSnapshot(AdapterSnapshot(
            sessions: [], nodes: [], requests: [], quotas: []
        ))
        let coordinator = Coordinator(store: store, adapters: [.codex: adapter])
        try await coordinator.start()

        try await coordinator.refreshQuotas()

        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.quotas[claude.id]?.usedPercent, 55)
        await coordinator.stop()
    }

    /// One failing provider must not stop the others from refreshing.
    func testRefreshQuotasContinuesWhenOneAdapterFails() async throws {
        let store = try makeCoordinatorStore()
        let healthy = TestAdapter()
        let fresh = try QuotaWindow(
            provider: .codex,
            accountID: "default",
            usedPercent: 42,
            windowDuration: 18_000,
            resetsAt: Date(timeIntervalSince1970: 1_787_000_000),
            fetchedAt: Date(),
            source: "codex-app-server"
        )
        await healthy.setSnapshot(AdapterSnapshot(
            sessions: [], nodes: [], requests: [], quotas: [fresh]
        ))
        let coordinator = Coordinator(store: store, adapters: [.codex: healthy])
        try await coordinator.start()

        try await coordinator.refreshQuotas()

        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.quotas[fresh.id]?.usedPercent, 42)
        await coordinator.stop()
    }

    func testProviderEventsPersistBeforeStateChangeIsPublished() async throws {
        let store = try makeCoordinatorStore()
        let adapter = TestAdapter()
        let coordinator = Coordinator(store: store, adapters: [.codex: adapter])
        try await coordinator.start()
        let changes = await coordinator.changes()
        var iterator = changes.makeAsyncIterator()
        let session = AgentSession.fixture(status: .working)

        try await coordinator.apply(.sessionUpserted(session))

        let sequence = await iterator.next()
        XCTAssertEqual(sequence, 1)
        let persisted = try await store.snapshot()
        XCTAssertEqual(persisted.sessions[session.id]?.status, .working)
        await coordinator.stop()
    }

    func testAuthoritativeSnapshotExpiresMissingProviderRequest() async throws {
        let store = try makeCoordinatorStore()
        let pending = PendingRequest.fixture(state: .pending)
        try await store.apply(.requestUpserted(pending))
        let adapter = TestAdapter()
        await adapter.setSnapshot(AdapterSnapshot(
            sessions: [],
            nodes: [],
            requests: [],
            quotas: [],
            requestsAreAuthoritative: true
        ))
        let coordinator = Coordinator(store: store, adapters: [.codex: adapter])

        try await coordinator.start()

        let snapshot = await coordinator.snapshot()
        let persisted = try await store.snapshot()
        XCTAssertEqual(snapshot.requests[pending.id]?.state, .expired)
        XCTAssertEqual(persisted.requests[pending.id]?.state, .expired)
        await coordinator.stop()
    }

    func testPersistedEndpointIsRestoredBeforeFirstReconcile() async throws {
        let store = try makeCoordinatorStore()
        let endpoint = ProviderEndpoint(
            id: "manual-1",
            provider: .codex,
            origin: .manual,
            baseURL: "http://127.0.0.1:41789",
            credentialReference: "keychain-ref",
            connected: true,
            lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await store.apply(.endpointUpserted(endpoint))
        let adapter = TestAdapter()
        let coordinator = Coordinator(store: store, adapters: [.codex: adapter])

        try await coordinator.start()

        let restored = await adapter.restoredEndpoints
        let restoredCountAtReconcile = await adapter.restoredEndpointCountAtReconcile
        XCTAssertEqual(restored, [endpoint])
        XCTAssertEqual(restoredCountAtReconcile, 1)
        await coordinator.stop()
    }
}

func makeCoordinatorStore() throws -> AgentHubStore {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentHubCoordinatorTests-\(UUID().uuidString)")
        .appendingPathComponent("agenthub.sqlite")
    return try AgentHubStore(databaseURL: url)
}
