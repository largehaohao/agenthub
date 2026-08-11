import XCTest
import AgentHubTestSupport
@testable import AgentHubCore

final class HandoffRouterTests: XCTestCase {
    func testPendingRequestBlocksDelivery() {
        let target = AgentSession.fixture(status: .waitingPermission)

        let result = HandoffRouter.eligibility(
            target: target,
            pendingRequests: [.fixture()]
        )

        XCTAssertEqual(result, .blockedByRequest)
    }

    func testIdleTargetCanReceiveImmediately() {
        XCTAssertEqual(
            HandoffRouter.eligibility(
                target: .fixture(status: .idle),
                pendingRequests: []
            ),
            .deliverNow
        )
    }

    func testWorkingTargetQueues() {
        XCTAssertEqual(
            HandoffRouter.eligibility(
                target: .fixture(status: .working),
                pendingRequests: []
            ),
            .queue
        )
    }

    func testRenderIncludesProvenanceNoteAndOnlyNewestTwentyTurns() {
        let source = AgentSession.fixture(title: "Source session")
        var envelope = MessageEnvelope.fixture()
        envelope.turns = (1...25).map {
            VisibleTurn(
                id: "turn-\($0)",
                role: "assistant",
                text: "output \($0)",
                createdAt: Date(timeIntervalSince1970: TimeInterval($0))
            )
        }
        envelope.userNote = "Focus on the failing test"

        let rendered = HandoffRouter.render(envelope, source: source)

        XCTAssertTrue(rendered.contains("Source session"))
        XCTAssertTrue(rendered.contains("Focus on the failing test"))
        XCTAssertFalse(rendered.contains("output 5\n"))
        XCTAssertTrue(rendered.contains("output 6"))
        XCTAssertTrue(rendered.contains("output 25"))
    }
}
