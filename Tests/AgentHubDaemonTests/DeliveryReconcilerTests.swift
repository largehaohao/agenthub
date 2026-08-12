import Foundation
import XCTest
import AgentHubCore
import AgentHubPersistence
import AgentHubTestSupport
@testable import AgentHubDaemon

final class DeliveryReconcilerTests: XCTestCase {
    func testWorkingToIdleTransitionReleasesQueuedHandoffOnce() async throws {
        let context = try await makeContext()
        let reconciler = DeliveryReconciler(handoffs: context.handoffs)

        await reconciler.reconcile(state(status: .working))
        await reconciler.reconcile(state(status: .idle))
        // A repeated snapshot of the same idle state must not redeliver.
        await reconciler.reconcile(state(status: .idle))

        let delivered = await context.adapter.sentInputs
        XCTAssertEqual(delivered.count, 1)
    }

    func testStayingIdleAcrossSnapshotsNeverRedelivers() async throws {
        let context = try await makeContext()
        let reconciler = DeliveryReconciler(handoffs: context.handoffs)

        for _ in 0..<3 {
            await reconciler.reconcile(state(status: .idle))
        }

        let delivered = await context.adapter.sentInputs
        XCTAssertTrue(delivered.isEmpty, "idle without a transition is not a release signal")
    }

    func testReturningToIdleAfterWorkingReleasesAgain() async throws {
        let context = try await makeContext()
        let reconciler = DeliveryReconciler(handoffs: context.handoffs)

        await reconciler.reconcile(state(status: .working))
        await reconciler.reconcile(state(status: .idle))
        try await context.store.apply(.envelopeUpserted(.fixture(state: .queued)))
        await reconciler.reconcile(state(status: .working))
        await reconciler.reconcile(state(status: .idle))

        let delivered = await context.adapter.sentInputs
        XCTAssertEqual(delivered.count, 2)
    }

    func testPendingRequestOnTheTargetBlocksAutomaticRelease() async throws {
        let context = try await makeContext()
        var request = PendingRequest.fixture(state: .pending)
        // The request must belong to the handoff target to block it.
        request.sessionID = targetSessionID
        try await context.store.apply(.requestUpserted(request))
        let reconciler = DeliveryReconciler(handoffs: context.handoffs)

        var busy = state(status: .working)
        busy.requests[request.id] = request
        var free = state(status: .idle)
        free.requests[request.id] = request

        await reconciler.reconcile(busy)
        await reconciler.reconcile(free)

        let delivered = await context.adapter.sentInputs
        XCTAssertTrue(delivered.isEmpty)
    }

    // MARK: - Helpers

    /// The session the queued envelope fixture is addressed to.
    private let targetSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private struct Context {
        let store: AgentHubStore
        let adapter: TestAdapter
        let handoffs: HandoffService
    }

    private func makeContext() async throws -> Context {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeliveryReconcilerTests-\(UUID().uuidString)")
            .appendingPathComponent("agenthub.sqlite")
        let store = try AgentHubStore(databaseURL: url)
        let adapter = TestAdapter()
        // Delivery renders the envelope against its source session, so both the
        // source session and the queued envelope must be persisted.
        try await store.apply(.sessionUpserted(.fixture()))
        try await store.apply(.envelopeUpserted(.fixture(state: .queued)))

        return Context(
            store: store,
            adapter: adapter,
            // The fixture envelope is dated 2023, so the clock must match it or
            // every delivery would be rejected as expired.
            handoffs: HandoffService(
                store: store,
                adapters: [.codex: adapter],
                now: { Date(timeIntervalSince1970: 1_700_000_000) }
            )
        )
    }

    private func state(status: SessionStatus) -> AgentHubState {
        var session = AgentSession.fixture(id: targetSessionID)
        session.status = status
        session.capabilities[.sendInput] = .l1
        var state = AgentHubState.empty
        state.sessions[session.id] = session
        return state
    }
}
