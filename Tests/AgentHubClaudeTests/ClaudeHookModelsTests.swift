import Foundation
import XCTest
@testable import AgentHubClaude

final class ClaudeHookModelsTests: XCTestCase {
    private let decoder = ClaudeHookDecoder()

    func testSessionStartDecodesCommonFields() throws {
        guard case .sessionStart(let value) = try decoder.decode(fixture("session-start")) else {
            return XCTFail("expected a session start event")
        }

        XCTAssertEqual(value.common.sessionID, "abc123")
        XCTAssertEqual(value.common.cwd, "/Users/example/repo")
        XCTAssertEqual(
            value.common.transcriptPath,
            "/Users/example/.claude/projects/repo/abc123.jsonl"
        )
        XCTAssertEqual(value.source, "startup")
    }

    func testPermissionAndQuestionDecodeWithoutLosingFieldOrder() throws {
        guard case .permissionRequest(let permission) =
            try decoder.decode(fixture("permission-request")) else {
            return XCTFail("expected a permission request event")
        }
        XCTAssertEqual(permission.common.sessionID, "abc123")
        XCTAssertEqual(permission.toolName, "Bash")
        XCTAssertEqual(permission.options, ["Yes", "Yes, and don't ask again", "No"])

        guard case .preToolUse(let question) =
            try decoder.decode(fixture("ask-user-question")) else {
            return XCTFail("expected a pre tool use event")
        }
        XCTAssertEqual(question.toolName, "AskUserQuestion")
        XCTAssertEqual(question.questions.map(\.prompt), ["Environment?", "Checks?"])
        XCTAssertEqual(
            question.questions.first?.options.map(\.label),
            ["Staging", "Production"]
        )
        XCTAssertEqual(question.questions.last?.allowsMultipleSelections, true)
    }

    func testSubagentAndTaskEventsCarryStableIdentifiers() throws {
        guard case .subagentStart(let start) = try decoder.decode(fixture("subagent-start")) else {
            return XCTFail("expected a subagent start event")
        }
        XCTAssertEqual(start.agentID, "agent-abc123")
        XCTAssertEqual(start.agentType, "Explore")

        guard case .subagentStop(let stop) = try decoder.decode(fixture("subagent-stop")) else {
            return XCTFail("expected a subagent stop event")
        }
        XCTAssertEqual(stop.agentID, "agent-abc123")

        guard case .taskCreated(let created) = try decoder.decode(fixture("task-created")) else {
            return XCTFail("expected a task created event")
        }
        XCTAssertEqual(created.taskID, "task-77")

        guard case .taskCompleted(let completed) =
            try decoder.decode(fixture("task-completed")) else {
            return XCTFail("expected a task completed event")
        }
        XCTAssertEqual(completed.taskID, "task-77")
        XCTAssertEqual(completed.status, "completed")
    }

    func testUnknownEventIsPreservedAsIgnoredName() throws {
        XCTAssertEqual(try decoder.decode(fixture("unknown-event")), .unknown("FutureEvent"))
    }

    func testAdditiveFieldsOnKnownEventsAreTolerated() throws {
        let payload = Data("""
        {
          "hook_event_name": "SessionStart",
          "session_id": "abc123",
          "transcript_path": "/Users/example/.claude/projects/repo/abc123.jsonl",
          "cwd": "/Users/example/repo",
          "brand_new_field": { "deeply": ["nested", 1, true, null] }
        }
        """.utf8)

        guard case .sessionStart(let value) = try decoder.decode(payload) else {
            return XCTFail("expected a session start event")
        }
        XCTAssertEqual(value.common.sessionID, "abc123")
    }

    func testMissingRequiredCommonFieldIsRejectedWithoutLeakingPayload() throws {
        let payload = Data("""
        {
          "hook_event_name": "SessionStart",
          "transcript_path": "/Users/example/.claude/projects/repo/abc123.jsonl",
          "cwd": "/Users/example/repo",
          "secret_token": "raw-secret-command"
        }
        """.utf8)

        XCTAssertThrowsError(try decoder.decode(payload)) { error in
            XCTAssertEqual(error as? ClaudeHookDecodingError, .malformedPayload)
            XCTAssertFalse(String(describing: error).contains("raw-secret-command"))
        }
    }

    func testMissingEventNameIsRejected() {
        let payload = Data("{\"session_id\":\"abc123\"}".utf8)
        XCTAssertThrowsError(try decoder.decode(payload)) { error in
            XCTAssertEqual(error as? ClaudeHookDecodingError, .malformedPayload)
        }
    }

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Claude/\(name).json")
        return try Data(contentsOf: url)
    }
}
