import Foundation
import XCTest
@testable import AgentHubCursor

final class CursorHookModelsTests: XCTestCase {
    private let decoder = CursorHookDecoder()

    func testSessionStartDecodesConversationAndWorkspace() throws {
        let payload = try decoder.decode(fixture("session-start"))
        XCTAssertEqual(payload.event, .sessionStart)
        XCTAssertEqual(payload.conversationID, "conv-fixture-1")
        XCTAssertEqual(payload.sessionID, "conv-fixture-1")
        XCTAssertEqual(payload.workspaceRoots, ["/Users/example/repo"])
        XCTAssertFalse(payload.requiresPermissionDecision)
    }

    func testBeforeShellExecutionRequiresPermissionDecision() throws {
        let payload = try decoder.decode(fixture("before-shell-execution"))
        XCTAssertEqual(payload.event, .beforeShellExecution)
        XCTAssertTrue(payload.requiresPermissionDecision)
        XCTAssertFalse(payload.conversationID.isEmpty)
        XCTAssertLessThanOrEqual(
            payload.boundedPreview.utf8.count,
            CursorHookPayload.maximumPreviewBytes
        )
        XCTAssertTrue(payload.boundedPreview.contains("gh pr create"))
    }

    func testBeforeMCPExecutionRequiresPermissionDecision() throws {
        let payload = try decoder.decode(fixture("before-mcp-execution"))
        XCTAssertEqual(payload.event, .beforeMCPExecution)
        XCTAssertTrue(payload.requiresPermissionDecision)
        XCTAssertEqual(payload.toolName, "browser_navigate")
        XCTAssertLessThanOrEqual(
            payload.boundedPreview.utf8.count,
            CursorHookPayload.maximumPreviewBytes
        )
    }

    func testSubagentAndStopDecode() throws {
        let subagent = try decoder.decode(fixture("subagent-start"))
        XCTAssertEqual(subagent.event, .subagentStart)
        XCTAssertEqual(subagent.subagentID, "sub-1")

        let stop = try decoder.decode(fixture("stop"))
        XCTAssertEqual(stop.event, .stop)
        XCTAssertEqual(stop.boundedPreview, "completed")
    }

    func testUnknownEventDoesNotThrow() throws {
        let data = Data(#"{"hook_event_name":"totally_new","conversation_id":"c1"}"#.utf8)
        let payload = try decoder.decode(data)
        XCTAssertEqual(payload.event, .unknown)
        XCTAssertFalse(payload.requiresPermissionDecision)
    }

    func testMissingConversationIDIsRejectedWithoutLeakingSecrets() {
        let data = Data(#"{"hook_event_name":"beforeShellExecution","command":"raw-secret"}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(data)) { error in
            XCTAssertEqual(error as? CursorHookDecodingError, .malformedPayload)
            XCTAssertFalse(String(describing: error).contains("raw-secret"))
        }
    }

    func testPreviewIsBoundedToTwoKiB() {
        let long = String(repeating: "x", count: 4_096)
        let bounded = CursorHookPayload.bounded(long)
        XCTAssertEqual(bounded.utf8.count, CursorHookPayload.maximumPreviewBytes)
    }

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Cursor/\(name).json")
        return try Data(contentsOf: url)
    }
}
