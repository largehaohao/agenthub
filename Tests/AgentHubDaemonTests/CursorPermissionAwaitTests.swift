import Foundation
import XCTest
import AgentHubCore
import AgentHubPersistence
import AgentHubTestSupport
@testable import AgentHubDaemon

final class CursorPermissionAwaitTests: XCTestCase {
    func testAwaitHookPermissionTimesOutToAsk() async throws {
        let store = try makeStore()
        let service = RequestService(store: store, adapters: [.codex: TestAdapter()])

        let decision = await service.awaitHookPermission(
            requestID: UUID(),
            timeoutMilliseconds: 50
        )
        XCTAssertEqual(decision, .ask)
    }

    func testAwaitHookPermissionReturnsAllowAfterAccept() async throws {
        let request = PendingRequest.fixture(state: .pending, provider: .cursor)
        let store = try makeStore()
        try await store.apply(.requestUpserted(request))
        let adapter = TestAdapter()
        let service = RequestService(store: store, adapters: [.cursor: adapter])

        async let waited = service.awaitHookPermission(
            requestID: request.id,
            timeoutMilliseconds: 2_000
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        try await service.resolve(id: request.id, decision: .accept)
        let decision = await waited
        XCTAssertEqual(decision, .allow)
    }

    func testAwaitHookPermissionReturnsDenyAfterDecline() async throws {
        let request = PendingRequest.fixture(state: .pending, provider: .cursor)
        let store = try makeStore()
        try await store.apply(.requestUpserted(request))
        let service = RequestService(store: store, adapters: [.cursor: TestAdapter()])

        async let waited = service.awaitHookPermission(
            requestID: request.id,
            timeoutMilliseconds: 2_000
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        try await service.resolve(id: request.id, decision: .decline)
        let decision = await waited
        XCTAssertEqual(decision, .deny)
    }
}

private func makeStore() throws -> AgentHubStore {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentHubDaemonTests-\(UUID().uuidString)")
        .appendingPathComponent("agenthub.sqlite")
    return try AgentHubStore(databaseURL: url)
}
