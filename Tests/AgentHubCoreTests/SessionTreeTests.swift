import XCTest
@testable import AgentHubCore
import AgentHubTestSupport

final class SessionTreeTests: XCTestCase {
    func testSameNativeIdentityProducesOneRoot() {
        XCTAssertEqual(
            SessionTreeBuilder.build(
                sessions: [.duplicateA, .duplicateB],
                nodes: []
            ).count,
            1
        )
    }

    func testExplicitParentNestsNodeUnderSession() {
        let rows = SessionTreeBuilder.build(
            sessions: [.fixture(nativeID: "root-thread")],
            nodes: [.fixture(parentNativeID: "root-thread")]
        )

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.children.count, 1)
    }
}
