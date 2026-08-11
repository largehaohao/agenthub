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
}

func makeCoordinatorStore() throws -> AgentHubStore {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentHubCoordinatorTests-\(UUID().uuidString)")
        .appendingPathComponent("agenthub.sqlite")
    return try AgentHubStore(databaseURL: url)
}
