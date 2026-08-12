import XCTest
@testable import AgentHubCore
import AgentHubTestSupport

final class StateReducerTests: XCTestCase {
    func testComponentUpsertUsesProviderAndComponentIdentity() {
        var state = AgentHubState.empty
        let status = ProviderComponentStatus(
            provider: .claude,
            component: "hooks",
            available: true,
            version: "2.1.228",
            path: "/tmp/agenthub-claude-hook",
            message: nil,
            changedAt: Date(timeIntervalSince1970: 1)
        )

        StateReducer.reduce(state: &state, event: .componentUpserted(status))

        XCTAssertEqual(state.components["claude:hooks"], status)
    }

    func testResolvedRequestNeverReturnsToResolving() {
        var state = AgentHubState.empty
        let request = PendingRequest.fixture(state: .pending)

        StateReducer.reduce(state: &state, event: .requestUpserted(request))
        StateReducer.reduce(
            state: &state,
            event: .requestResolved(id: request.id, outcome: "accepted")
        )
        StateReducer.reduce(
            state: &state,
            event: .requestResolutionStarted(id: request.id)
        )

        XCTAssertEqual(state.requests[request.id]?.state, .resolved)
    }

    func testResolvedRequestIgnoresLateExpiredSnapshot() {
        var state = AgentHubState.empty
        let resolved = PendingRequest.fixture(state: .resolved)
        let expired = PendingRequest.fixture(state: .expired)

        StateReducer.reduce(state: &state, event: .requestUpserted(resolved))
        StateReducer.reduce(state: &state, event: .requestUpserted(expired))

        XCTAssertEqual(state.requests[resolved.id]?.state, .resolved)
    }

    func testRequestExpiredMovesPendingRequestToExpired() {
        var pendingState = AgentHubState.empty
        let pending = PendingRequest.fixture(state: .pending)
        StateReducer.reduce(state: &pendingState, event: .requestUpserted(pending))

        StateReducer.reduce(state: &pendingState, event: .requestExpired(id: pending.id))

        XCTAssertEqual(pendingState.requests[pending.id]?.state, .expired)
    }

    func testRequestExpiredDoesNotChangeResolvedRequest() {
        var resolvedState = AgentHubState.empty
        let resolved = PendingRequest.fixture(state: .resolved)
        StateReducer.reduce(state: &resolvedState, event: .requestUpserted(resolved))
        StateReducer.reduce(state: &resolvedState, event: .requestExpired(id: resolved.id))
        XCTAssertEqual(resolvedState.requests[resolved.id]?.state, .resolved)
    }
}
