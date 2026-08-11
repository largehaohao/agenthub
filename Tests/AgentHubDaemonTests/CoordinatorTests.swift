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
