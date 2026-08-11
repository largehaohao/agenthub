import Foundation
import XCTest
import AgentHubCore
import AgentHubPersistence
import AgentHubTestSupport
@testable import AgentHubDaemon

final class RequestServiceTests: XCTestCase {
    func testResolvedRequestCannotSubmitAgain() async throws {
        let request = PendingRequest.fixture(state: .resolved)
        let store = try makeStore()
        try await store.apply(.requestUpserted(request))
        let adapter = TestAdapter()
        let service = RequestService(store: store, adapters: [.codex: adapter])

        do {
            try await service.resolve(id: request.id, decision: .accept)
            XCTFail("resolved request was submitted twice")
        } catch {
            XCTAssertEqual(error as? RequestServiceError, .notPending)
        }
        let submittedCount = await adapter.resolvedRequests.count
        XCTAssertEqual(submittedCount, 0)
    }

    func testPendingRequestTransitionsToResolvedAfterProviderAccepts() async throws {
        let request = PendingRequest.fixture(state: .pending)
        let store = try makeStore()
        try await store.apply(.requestUpserted(request))
        let adapter = TestAdapter()
        let service = RequestService(store: store, adapters: [.codex: adapter])

        try await service.resolve(id: request.id, decision: .accept)

        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.requests[request.id]?.state, .resolved)
        let submitted = await adapter.resolvedRequests
        XCTAssertEqual(submitted.count, 1)
        XCTAssertEqual(submitted.first?.0.requestID, "approval-1")
    }

    func testProviderAlreadyResolvedIsIdempotentSuccess() async throws {
        let request = PendingRequest.fixture(state: .pending)
        let store = try makeStore()
        try await store.apply(.requestUpserted(request))
        let adapter = TestAdapter()
        await adapter.setResolveError(.requestAlreadyResolved)
        let service = RequestService(store: store, adapters: [.codex: adapter])

        try await service.resolve(id: request.id, decision: .accept)

        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.requests[request.id]?.state, .resolved)
    }
}

private extension TestAdapter {
    func setResolveError(_ error: AdapterOperationError?) {
        resolveError = error
    }
}

private func makeStore() throws -> AgentHubStore {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentHubDaemonTests-\(UUID().uuidString)")
        .appendingPathComponent("agenthub.sqlite")
    return try AgentHubStore(databaseURL: url)
}
