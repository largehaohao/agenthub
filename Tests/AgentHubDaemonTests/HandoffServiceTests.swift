import Foundation
import XCTest
import AgentHubCore
import AgentHubPersistence
import AgentHubTestSupport
@testable import AgentHubDaemon

final class HandoffServiceTests: XCTestCase {
    func testWorkingTargetQueuesWithoutSending() async throws {
        let adapter = TestAdapter()
        let store = try makeHandoffStore()
        let service = HandoffService(
            store: store,
            adapters: [.codex: adapter],
            now: { Date(timeIntervalSince1970: 1_700_000_100) }
        )
        var envelope = MessageEnvelope.fixture()
        envelope.expiresAt = Date(timeIntervalSince1970: 1_700_000_300)
        envelope.turns = (1...25).map {
            VisibleTurn(
                id: "turn-\($0)",
                role: "assistant",
                text: "output \($0)",
                createdAt: Date(timeIntervalSince1970: TimeInterval($0))
            )
        }
        let source = AgentSession.fixture()
        let target = AgentSession.fixture(
            id: envelope.targetSessionID,
            nativeID: "codex-2",
            status: .working
        )
        try await store.apply(.sessionUpserted(source))
        try await store.apply(.sessionUpserted(target))

        try await service.submit(
            envelope,
            target: target,
            pendingRequests: []
        )

        let sendCount = await adapter.sentInputs.count
        let snapshot = try await store.snapshot()
        XCTAssertEqual(sendCount, 0)
        XCTAssertEqual(snapshot.envelopes[envelope.id]?.state, .queued)
        XCTAssertEqual(snapshot.envelopes[envelope.id]?.turns.count, 20)
    }

    func testIdleTargetDeliversAndPersistsDeliveredState() async throws {
        let adapter = TestAdapter()
        let store = try makeHandoffStore()
        let service = HandoffService(
            store: store,
            adapters: [.codex: adapter],
            now: { Date(timeIntervalSince1970: 1_700_000_100) }
        )
        var envelope = MessageEnvelope.fixture()
        envelope.expiresAt = Date(timeIntervalSince1970: 1_700_000_300)
        let source = AgentSession.fixture()
        let target = AgentSession.fixture(
            id: envelope.targetSessionID,
            nativeID: "codex-2",
            status: .idle
        )
        try await store.apply(.sessionUpserted(source))
        try await store.apply(.sessionUpserted(target))

        try await service.submit(
            envelope,
            target: target,
            pendingRequests: []
        )

        let sendCount = await adapter.sentInputs.count
        let snapshot = try await store.snapshot()
        XCTAssertEqual(sendCount, 1)
        XCTAssertEqual(snapshot.envelopes[envelope.id]?.state, .delivered)
    }

    func testExpiredHandoffNeverSends() async throws {
        let adapter = TestAdapter()
        let store = try makeHandoffStore()
        let service = HandoffService(
            store: store,
            adapters: [.codex: adapter],
            now: { Date(timeIntervalSince1970: 1_700_000_301) }
        )
        let envelope = MessageEnvelope.fixture()
        let target = AgentSession.fixture(
            id: envelope.targetSessionID,
            nativeID: "codex-2",
            status: .idle
        )

        do {
            try await service.submit(
                envelope,
                target: target,
                pendingRequests: []
            )
            XCTFail("expired handoff was delivered")
        } catch {
            XCTAssertEqual(error as? HandoffServiceError, .expired)
        }
        let sendCount = await adapter.sentInputs.count
        XCTAssertEqual(sendCount, 0)
    }

    func testDeliveredHandoffCannotBeRetried() async throws {
        let adapter = TestAdapter()
        let store = try makeHandoffStore()
        let service = HandoffService(
            store: store,
            adapters: [.codex: adapter],
            now: { Date(timeIntervalSince1970: 1_700_000_100) }
        )
        var envelope = MessageEnvelope.fixture(state: .delivered)
        envelope.expiresAt = Date(timeIntervalSince1970: 1_700_000_300)
        let source = AgentSession.fixture()
        let target = AgentSession.fixture(
            id: envelope.targetSessionID,
            nativeID: "codex-2",
            status: .idle
        )
        try await store.apply(.sessionUpserted(source))
        try await store.apply(.sessionUpserted(target))
        try await store.apply(.envelopeUpserted(envelope))

        do {
            try await service.retry(id: envelope.id)
            XCTFail("delivered handoff was sent twice")
        } catch {
            XCTAssertEqual(error as? HandoffServiceError, .notRetryable)
        }
        let sendCount = await adapter.sentInputs.count
        XCTAssertEqual(sendCount, 0)
    }

    func testProviderFailureDoesNotPersistSensitiveErrorText() async throws {
        struct SensitiveProviderError: Error, CustomStringConvertible {
            let description = "Bearer private-token"
        }

        let adapter = TestAdapter()
        await adapter.setSendError(SensitiveProviderError())
        let store = try makeHandoffStore()
        let service = HandoffService(
            store: store,
            adapters: [.codex: adapter],
            now: { Date(timeIntervalSince1970: 1_700_000_100) }
        )
        var envelope = MessageEnvelope.fixture()
        envelope.expiresAt = Date(timeIntervalSince1970: 1_700_000_300)
        let source = AgentSession.fixture()
        let target = AgentSession.fixture(
            id: envelope.targetSessionID,
            nativeID: "codex-2",
            status: .idle
        )
        try await store.apply(.sessionUpserted(source))
        try await store.apply(.sessionUpserted(target))

        do {
            try await service.submit(envelope, target: target, pendingRequests: [])
            XCTFail("provider failure was swallowed")
        } catch is SensitiveProviderError {
            // Expected provider error remains available to the immediate caller.
        }

        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.envelopes[envelope.id]?.state, .failed)
        XCTAssertEqual(snapshot.envelopes[envelope.id]?.failure, "Delivery failed")
    }
}

private func makeHandoffStore() throws -> AgentHubStore {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentHubHandoffTests-\(UUID().uuidString)")
        .appendingPathComponent("agenthub.sqlite")
    return try AgentHubStore(databaseURL: url)
}
