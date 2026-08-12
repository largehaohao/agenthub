import Foundation
import XCTest
import AgentHubCore
@testable import AgentHubCursor

final class CursorPermissionGateTests: XCTestCase {
    func testPermissionGateNeverSerializesDefaultAllowOnUnknown() throws {
        let data = CursorPermissionGate.responseJSON(for: .ask)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["permission"] as? String, "ask")
    }

    func testAllowAndDenySerializeExactCursorKeys() throws {
        for decision in [HookPermissionDecision.allow, .deny] {
            let obj = try JSONSerialization.jsonObject(
                with: CursorPermissionGate.responseJSON(for: decision)
            ) as! [String: Any]
            XCTAssertEqual(obj["permission"] as? String, decision.rawValue)
        }
    }

    func testRequestDecisionMappingNeverDefaultsTextToAllow() {
        XCTAssertEqual(CursorPermissionGate.decision(from: .accept), .allow)
        XCTAssertEqual(CursorPermissionGate.decision(from: .decline), .deny)
        XCTAssertEqual(CursorPermissionGate.decision(from: .text("yes")), .ask)
    }
}
