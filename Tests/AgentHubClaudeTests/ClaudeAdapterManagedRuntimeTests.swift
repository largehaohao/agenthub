import Foundation
import XCTest
import AgentHubCore
@testable import AgentHubClaude

final class ClaudeAdapterManagedRuntimeTests: XCTestCase {
    private let claudeID = UUID(uuidString: "A1B2C3D4-0000-0000-0000-00000000FFFF")!
    private var terminal: RecordingManagedTerminal!
    private var adapter: ClaudeAdapter!

    override func setUp() {
        super.setUp()
        terminal = RecordingManagedTerminal(captured: idleScreen)
        adapter = makeAdapter()
    }

    // MARK: - Launch

    func testLaunchWaitsForMatchingSessionStartThenPastesPromptOnce() async throws {
        let started = adapter!
        let request = launchRequest(prompt: "Build it")
        let launch = Task { try await started.launch(request) }
        try await settle()
        try await adapter.ingest(managedSessionStart())

        let reference = try await launch.value

        XCTAssertEqual(reference.nativeID, claudeID.uuidString)
        let pasted = await terminal.pastedTexts()
        XCTAssertEqual(pasted, ["Build it"])
        let submits = await terminal.submitCount()
        XCTAssertEqual(submits, 1)
    }

    func testLaunchNeverPassesThePromptAsAProcessArgument() async throws {
        let started = adapter!
        let request = launchRequest(prompt: "Build it")
        let launch = Task { try await started.launch(request) }
        try await settle()
        try await adapter.ingest(managedSessionStart())
        _ = try await launch.value

        let launches = await terminal.launchCalls()
        XCTAssertEqual(launches.count, 1)
        XCTAssertFalse(String(describing: launches).contains("Build it"))
        XCTAssertEqual(launches.first?.claudeSessionID, claudeID)
    }

    func testLaunchTimeoutLeavesOneRecoverableSession() async throws {
        // No SessionStart is ever ingested, so the handshake must time out.
        do {
            _ = try await adapter.launch(launchRequest(prompt: "Build it"))
            XCTFail("expected the launch handshake to time out")
        } catch {
            XCTAssertEqual(error as? ClaudeAdapterError, .launchTimedOut)
        }

        let snapshot = try await adapter.reconcile()
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.sessions.first?.status, .error)
        let pasted = await terminal.pastedTexts()
        XCTAssertTrue(pasted.isEmpty)
    }

    func testLaunchRefusesToPasteIntoANonIdleComposer() async throws {
        terminal = RecordingManagedTerminal(captured: workingScreen)
        adapter = makeAdapter()

        let started = adapter!
        let request = launchRequest(prompt: "Build it")
        let launch = Task { try await started.launch(request) }
        try await settle()
        try await adapter.ingest(managedSessionStart())

        do {
            _ = try await launch.value
            XCTFail("expected a busy composer to block prompt delivery")
        } catch {
            XCTAssertEqual(error as? ClaudeTerminalError, .stalePrompt)
        }

        let pasted = await terminal.pastedTexts()
        XCTAssertTrue(pasted.isEmpty)
        // The session stays visible so the user can retry rather than losing it.
        let snapshot = try await adapter.reconcile()
        XCTAssertEqual(snapshot.sessions.count, 1)
    }

    // MARK: - Send

    func testSendRejectsBusyManagedTarget() async throws {
        let reference = try await establishManagedSession()
        try await adapter.ingest(managedEvent("UserPromptSubmit"))

        do {
            try await adapter.send(AgentInput(text: "handoff"), to: reference)
            XCTFail("expected a working session to reject direct input")
        } catch {
            XCTAssertEqual(error as? ClaudeAdapterError, .sessionBusy)
        }

        let pasted = await terminal.pastedTexts()
        XCTAssertTrue(pasted.isEmpty)
    }

    func testSendRejectsManagedTargetWithPendingRequest() async throws {
        let reference = try await establishManagedSession()
        try await adapter.ingest(managedPermissionRequest())

        do {
            try await adapter.send(AgentInput(text: "handoff"), to: reference)
            XCTFail("expected a pending request to block delivery")
        } catch {
            XCTAssertEqual(error as? ClaudeAdapterError, .sessionBusy)
        }

        let pasted = await terminal.pastedTexts()
        XCTAssertTrue(pasted.isEmpty)
    }

    func testSendDeliversOnceToAnIdleManagedTarget() async throws {
        let reference = try await establishManagedSession()

        try await adapter.send(AgentInput(text: "handoff"), to: reference)

        let pasted = await terminal.pastedTexts()
        XCTAssertEqual(pasted, ["handoff"])
        let submits = await terminal.submitCount()
        XCTAssertEqual(submits, 1)
    }

    // MARK: - Resolve and jump

    func testResolveUsesTheCapturedFingerprintOfTheLiveScreen() async throws {
        _ = try await establishManagedSession()
        await terminal.setCaptured(permissionScreen)
        try await adapter.ingest(managedPermissionRequest())

        let snapshot = try await adapter.reconcile()
        let request = try XCTUnwrap(snapshot.requests.first)

        try await adapter.resolve(
            ProviderRequestRef(
                provider: .claude,
                requestID: request.providerRequestID,
                threadID: request.threadID
            ),
            decision: .accept
        )

        let pasted = await terminal.pastedTexts()
        XCTAssertEqual(pasted, ["Yes"])
    }

    func testResolveRefusesWhenTheScreenChangedAfterTheRequest() async throws {
        _ = try await establishManagedSession()
        await terminal.setCaptured(permissionScreen)
        try await adapter.ingest(managedPermissionRequest())

        let snapshot = try await adapter.reconcile()
        let request = try XCTUnwrap(snapshot.requests.first)
        // Claude moved on before the user clicked.
        await terminal.setCaptured(workingScreen)

        do {
            try await adapter.resolve(
                ProviderRequestRef(
                    provider: .claude,
                    requestID: request.providerRequestID,
                    threadID: request.threadID
                ),
                decision: .accept
            )
            XCTFail("expected a changed screen to block resolution")
        } catch {
            XCTAssertEqual(error as? ClaudeTerminalError, .stalePrompt)
        }

        let pasted = await terminal.pastedTexts()
        XCTAssertTrue(pasted.isEmpty)
    }

    func testManagedJumpSelectsTmuxThenReturnsITermActivation() async throws {
        let reference = try await establishManagedSession()

        let target = await adapter.jumpTarget(for: reference)

        guard case .application(let bundleID, let windowHint) = target else {
            return XCTFail("expected an iTerm activation target")
        }
        XCTAssertEqual(bundleID, "com.googlecode.iterm2")
        XCTAssertEqual(windowHint, "agenthub-a1b2c3d4")
        let selected = await terminal.selectedSessions()
        XCTAssertEqual(selected, ["agenthub-a1b2c3d4"])
    }

    func testManagedSessionAdvertisesSendInput() async throws {
        _ = try await establishManagedSession()

        let snapshot = try await adapter.reconcile()
        let session = try XCTUnwrap(snapshot.sessions.first)

        XCTAssertEqual(session.ownership, .managed)
        XCTAssertEqual(session.surface, "Managed CLI")
        XCTAssertEqual(session.capabilities[.sendInput], .l2)
        XCTAssertEqual(session.capabilities[.jump], .l2)
    }

    // MARK: - Helpers

    private func makeAdapter() -> ClaudeAdapter {
        ClaudeAdapter(
            accountID: "personal",
            terminal: terminal,
            makeSessionID: { [claudeID] in claudeID },
            launchTimeout: .milliseconds(200),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    /// Completes a managed launch and returns the resulting session reference.
    private func establishManagedSession() async throws -> ProviderSessionRef {
        let started = adapter!
        let request = launchRequest(prompt: "Build it")
        let launch = Task { try await started.launch(request) }
        try await settle()
        try await adapter.ingest(managedSessionStart())
        let reference = try await launch.value
        await terminal.reset()
        return reference
    }

    /// Lets the launch task reach its wait state before the hook arrives.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(20))
    }

    private func launchRequest(prompt: String) -> LaunchRequest {
        LaunchRequest(
            clientRequestID: "client-1",
            cwd: "/Users/example/repo",
            prompt: prompt,
            agent: nil,
            model: nil
        )
    }

    private func managedSessionStart() throws -> ProviderHookEnvelope {
        try managedEvent("SessionStart")
    }

    private func managedPermissionRequest() throws -> ProviderHookEnvelope {
        try managedEvent(
            "PermissionRequest",
            extra: [
                "tool_name": "Bash",
                "permission_suggestions": ["Yes", "Yes, and don't ask again", "No"],
            ]
        )
    }

    private func managedEvent(
        _ name: String,
        extra: [String: Any] = [:]
    ) throws -> ProviderHookEnvelope {
        var object: [String: Any] = [
            "hook_event_name": name,
            "session_id": claudeID.uuidString,
            "transcript_path": "/Users/example/.claude/projects/repo/session.jsonl",
            "cwd": "/Users/example/repo",
        ]
        for (key, value) in extra { object[key] = value }

        return try ProviderHookEnvelope(
            provider: .claude,
            rawJSON: try JSONSerialization.data(withJSONObject: object),
            sourcePID: 41,
            ancestors: [
                ProcessObservation(pid: 41, parentPID: 40, uid: 501, tty: "ttys001", command: "claude"),
                ProcessObservation(pid: 40, parentPID: 1, uid: 501, tty: nil, command: "tmux"),
            ],
            observedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private var idleScreen: String {
        "╭────╮\n│ >  │\n╰────╯\n  ? for shortcuts"
    }

    private var workingScreen: String {
        "Updating the reducer… (esc to interrupt)\n\n╭────╮\n│ >  │\n╰────╯"
    }

    private var permissionScreen: String {
        """
        ╭─────────────╮
        │ Do you want to proceed? │
        │ ❯ 1. Yes │
        │   2. Yes, and don't ask again │
        │   3. No │
        ╰─────────────╯
        """
    }
}

actor RecordingManagedTerminal: ClaudeTerminalControlling {
    struct LaunchCall: Equatable {
        let name: String
        let claudeSessionID: UUID
        let title: String
        let cwd: String
        let model: String?
    }

    private var captured: String
    private var pasted: [String] = []
    private var submits = 0
    private var launches: [LaunchCall] = []
    private var selected: [String] = []

    init(captured: String) {
        self.captured = captured
    }

    func setCaptured(_ value: String) { captured = value }

    func reset() {
        pasted = []
        submits = 0
        selected = []
    }

    func pastedTexts() -> [String] { pasted }
    func submitCount() -> Int { submits }
    func launchCalls() -> [LaunchCall] { launches }
    func selectedSessions() -> [String] { selected }

    func launch(
        name: String,
        claudeSessionID: UUID,
        title: String,
        cwd: String,
        model: String?
    ) async throws -> ClaudeManagedRuntime {
        launches.append(
            LaunchCall(
                name: name,
                claudeSessionID: claudeSessionID,
                title: title,
                cwd: cwd,
                model: model
            )
        )
        return ClaudeManagedRuntime(
            sessionName: name,
            paneID: "%3",
            claudeSessionID: claudeSessionID,
            cwd: cwd
        )
    }

    func listManaged() async throws -> [ClaudeManagedRuntime] { [] }

    func capture(paneID: String) async throws -> String { captured }

    func pasteLiteral(_ text: String, paneID: String) async throws { pasted.append(text) }

    func submit(paneID: String) async throws { submits += 1 }

    func select(sessionName: String) async throws { selected.append(sessionName) }

    func attach(sessionName: String) async throws {}

    func isAlive(sessionName: String) async throws -> Bool { true }
}
