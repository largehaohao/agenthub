import XCTest
@testable import AgentHubCore
import AgentHubTestSupport

final class StateReducerTests: XCTestCase {
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
}
