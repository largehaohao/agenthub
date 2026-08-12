import Foundation
import XCTest
import AgentHubCore
@testable import AgentHubClaude

final class ClaudeAdapterTests: XCTestCase {
    private var adapter: ClaudeAdapter!

    override func setUp() {
        super.setUp()
        adapter = ClaudeAdapter(
            accountID: "personal",
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    // MARK: - Sessions and nodes

    func testHooksCreateSeparateCLIAndDesktopSessionsAndExplicitNodes() async throws {
        try await adapter.ingest(hook(fixture: "session-start", ancestors: cliAncestry))
        try await adapter.ingest(
            hook(fixture: "session-start", sessionID: "desktop1", ancestors: desktopAncestry)
        )
        try await adapter.ingest(hook(fixture: "subagent-start", ancestors: cliAncestry))

        let snapshot = try await adapter.reconcile()

        XCTAssertEqual(snapshot.sessions.map(\.surface).sorted(), ["Desktop", "External CLI"])
        XCTAssertEqual(snapshot.nodes.count, 1)
        XCTAssertEqual(snapshot.nodes.first?.nativeID, "agent-abc123")
        XCTAssertNil(snapshot.nodes.first?.parentNativeID)
    }

    func testSameSessionIDOnDifferentSurfacesStaysSeparate() async throws {
        try await adapter.ingest(hook(fixture: "session-start", ancestors: cliAncestry))
        try await adapter.ingest(hook(fixture: "session-start", ancestors: desktopAncestry))

        let snapshot = try await adapter.reconcile()

        XCTAssertEqual(snapshot.sessions.count, 2)
    }

    func testDuplicateHookEventsAreIdempotent() async throws {
        for _ in 0..<3 {
            try await adapter.ingest(hook(fixture: "session-start", ancestors: cliAncestry))
        }

        let snapshot = try await adapter.reconcile()
        XCTAssertEqual(snapshot.sessions.count, 1)
    }

    // MARK: - Lifecycle

    func testLifecycleEventsMapToSessionStatus() async throws {
        try await adapter.ingest(hook(fixture: "session-start", ancestors: cliAncestry))
        var current = try await status()
        XCTAssertEqual(current, .idle)

        try await adapter.ingest(event("UserPromptSubmit"))
        current = try await status()
        XCTAssertEqual(current, .working)

        try await adapter.ingest(hook(fixture: "permission-request", ancestors: cliAncestry))
        current = try await status()
        XCTAssertEqual(current, .waitingPermission)

        try await adapter.ingest(event("Stop"))
        current = try await status()
        XCTAssertEqual(current, .idle)

        try await adapter.ingest(event("SessionEnd"))
        current = try await status()
        XCTAssertEqual(current, .completed)
    }

    func testStopFailureMapsToError() async throws {
        try await adapter.ingest(hook(fixture: "session-start", ancestors: cliAncestry))
        try await adapter.ingest(event("StopFailure"))

        let current = try await status()
        XCTAssertEqual(current, .error)
    }

    // MARK: - Requests

    func testPermissionHookCreatesAPendingRequestWithoutRawToolInput() async throws {
        try await adapter.ingest(hook(fixture: "session-start", ancestors: cliAncestry))
        try await adapter.ingest(hook(fixture: "permission-request", ancestors: cliAncestry))

        let snapshot = try await adapter.reconcile()
        let request = try XCTUnwrap(snapshot.requests.first)

        XCTAssertEqual(request.kind, .permission)
        XCTAssertEqual(request.provider, .claude)
        // The command itself is never mirrored into AgentHub storage.
        XCTAssertFalse(String(describing: request).contains("rm -rf build"))
    }

    func testAskUserQuestionCreatesAChoiceRequest() async throws {
        try await adapter.ingest(hook(fixture: "session-start", ancestors: cliAncestry))
        try await adapter.ingest(hook(fixture: "ask-user-question", ancestors: cliAncestry))

        let snapshot = try await adapter.reconcile()
        let request = try XCTUnwrap(snapshot.requests.first)

        XCTAssertEqual(request.kind, .choice)
        XCTAssertEqual(request.allowedActions, ["Staging", "Production"])
    }

    func testPostToolUseClosesTheMatchingRequest() async throws {
        try await adapter.ingest(hook(fixture: "session-start", ancestors: cliAncestry))
        try await adapter.ingest(hook(fixture: "permission-request", ancestors: cliAncestry))
        let before = try await adapter.reconcile()
        XCTAssertEqual(before.requests.count, 1)

        try await adapter.ingest(event("PostToolUse", extra: ["tool_name": "Bash"]))

        let after = try await adapter.reconcile()
        XCTAssertTrue(after.requests.isEmpty)
    }

    func testPermissionDeniedClosesTheMatchingRequest() async throws {
        try await adapter.ingest(hook(fixture: "session-start", ancestors: cliAncestry))
        try await adapter.ingest(hook(fixture: "permission-request", ancestors: cliAncestry))

        try await adapter.ingest(event("PermissionDenied", extra: ["tool_name": "Bash"]))

        let after = try await adapter.reconcile()
        XCTAssertTrue(after.requests.isEmpty)
    }

    // MARK: - Routing

    func testNativeResolutionRouteContainsNoRawToolPayload() async throws {
        try await adapter.ingest(
            hook(fixture: "session-start", sessionID: "desktop1", ancestors: desktopAncestry)
        )
        try await adapter.ingest(
            hook(fixture: "permission-request", sessionID: "desktop1", ancestors: desktopAncestry)
        )

        let snapshot = try await adapter.reconcile()
        let request = try XCTUnwrap(snapshot.requests.first)
        let route = try await adapter.resolutionRoute(
            ProviderRequestRef(
                provider: .claude,
                requestID: request.providerRequestID,
                threadID: request.threadID
            ),
            decision: .accept
        )

        guard case .native(let plan) = route else {
            return XCTFail("expected a native interaction plan for Desktop")
        }
        XCTAssertEqual(plan.bundleID, "com.anthropic.claudefordesktop")
        XCTAssertFalse(String(describing: plan).contains("rm -rf"))
    }

    func testUnknownRequestRouteIsRejected() async throws {
        do {
            _ = try await adapter.resolutionRoute(
                ProviderRequestRef(provider: .claude, requestID: "absent", threadID: "abc123"),
                decision: .accept
            )
            XCTFail("expected an unknown request to be rejected")
        } catch {
            XCTAssertEqual(error as? ClaudeAdapterError, .sessionNotFound)
        }
    }

    // MARK: - Capabilities

    func testDiscoveredSessionsDoNotAdvertiseSendInput() async throws {
        try await adapter.ingest(hook(fixture: "session-start", ancestors: cliAncestry))

        let snapshot = try await adapter.reconcile()
        let session = try XCTUnwrap(snapshot.sessions.first)

        XCTAssertNil(session.capabilities[.sendInput])
        XCTAssertEqual(session.ownership, .discovered)
        XCTAssertEqual(session.capabilities[.jump], .l3)
    }

    func testSendToADiscoveredSessionIsRejected() async throws {
        try await adapter.ingest(hook(fixture: "session-start", ancestors: cliAncestry))
        let snapshot = try await adapter.reconcile()
        let reference = try XCTUnwrap(snapshot.sessions.first).providerRef

        do {
            try await adapter.send(AgentInput(text: "hello"), to: reference)
            XCTFail("expected an unmanaged session to reject direct input")
        } catch {
            XCTAssertEqual(error as? ClaudeAdapterError, .unsupportedCapability)
        }
    }

    func testMismatchedProviderHookIsRejected() async throws {
        let foreign = try ProviderHookEnvelope(
            provider: .codex,
            rawJSON: Data("{}".utf8),
            sourcePID: 41,
            ancestors: [],
            observedAt: Date(timeIntervalSince1970: 1)
        )

        do {
            try await adapter.ingest(foreign)
            XCTFail("expected a foreign provider hook to be rejected")
        } catch {
            XCTAssertEqual(error as? ClaudeAdapterError, .unsupportedCapability)
        }
    }

    // MARK: - Helpers

    private func status() async throws -> SessionStatus? {
        try await adapter.reconcile().sessions.first?.status
    }

    private var cliAncestry: [ProcessObservation] {
        [observation(pid: 41, command: "claude"), observation(pid: 40, command: "zsh")]
    }

    private var desktopAncestry: [ProcessObservation] {
        [
            observation(pid: 41, command: "claude"),
            observation(pid: 40, command: "/Applications/Claude.app/Contents/MacOS/Claude"),
        ]
    }

    private func observation(pid: Int32, command: String) -> ProcessObservation {
        ProcessObservation(
            pid: pid,
            parentPID: pid - 1,
            uid: 501,
            tty: "ttys001",
            command: command
        )
    }

    private func hook(
        fixture name: String,
        sessionID: String? = nil,
        ancestors: [ProcessObservation]
    ) throws -> ProviderHookEnvelope {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Claude/\(name).json")
        var raw = try Data(contentsOf: url)

        if let sessionID {
            let text = String(decoding: raw, as: UTF8.self)
                .replacingOccurrences(of: "\"abc123\"", with: "\"\(sessionID)\"")
            raw = Data(text.utf8)
        }

        return try ProviderHookEnvelope(
            provider: .claude,
            rawJSON: raw,
            sourcePID: 41,
            ancestors: ancestors,
            observedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func event(
        _ name: String,
        sessionID: String = "abc123",
        extra: [String: String] = [:]
    ) throws -> ProviderHookEnvelope {
        var object: [String: Any] = [
            "hook_event_name": name,
            "session_id": sessionID,
            "transcript_path": "/Users/example/.claude/projects/repo/\(sessionID).jsonl",
            "cwd": "/Users/example/repo",
        ]
        for (key, value) in extra { object[key] = value }

        return try ProviderHookEnvelope(
            provider: .claude,
            rawJSON: try JSONSerialization.data(withJSONObject: object),
            sourcePID: 41,
            ancestors: cliAncestry,
            observedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
