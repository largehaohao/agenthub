import Foundation
import XCTest
@testable import AgentHubCore
import AgentHubTestSupport

final class ModelTests: XCTestCase {
    func testSessionRoundTripKeepsIdentity() throws {
        let session = AgentSession.fixture(status: .waitingPermission)
        let data = try JSONEncoder.agentHub.encode(session)

        XCTAssertEqual(
            try JSONDecoder.agentHub.decode(AgentSession.self, from: data),
            session
        )
    }

    func testQuotaRejectsOutOfRangePercent() {
        XCTAssertThrowsError(
            try QuotaWindow(
                provider: .codex,
                accountID: "personal",
                usedPercent: 101,
                windowDuration: 900,
                resetsAt: .now,
                fetchedAt: .now,
                source: "codex-app-server"
            )
        )
    }
}
