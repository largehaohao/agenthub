import Foundation
import XCTest
import AgentHubCore
@testable import AgentHubClaude

final class ClaudeTerminalScreenTests: XCTestCase {
    private let managed = ClaudeManagedRuntime(
        sessionName: "agenthub-a1b2c3d4",
        paneID: "%3",
        claudeSessionID: UUID(uuidString: "A1B2C3D4-0000-0000-0000-00000000FFFF")!,
        cwd: "/tmp/repo"
    )

    // MARK: - Parsing

    func testPermissionScreenMapsVisibleLabelsAndStableFingerprint() throws {
        let screen = try ClaudeTerminalScreen.parse(fixture("permission-screen"))

        XCTAssertEqual(
            screen.requestOptions.map(\.label),
            ["Yes", "Yes, and don't ask again", "No"]
        )
        XCTAssertFalse(screen.fingerprint.isEmpty)
        XCTAssertFalse(screen.isIdleComposer)
    }

    func testQuestionScreenMapsNumberedChoices() throws {
        let screen = try ClaudeTerminalScreen.parse(fixture("question-screen"))

        XCTAssertEqual(screen.requestOptions.map(\.label), ["Staging", "Production"])
        XCTAssertEqual(screen.requestOptions.map(\.index), [1, 2])
    }

    func testIdleComposerIsDetectedAndExposesNoOptions() throws {
        let screen = try ClaudeTerminalScreen.parse(fixture("idle-screen"))

        XCTAssertTrue(screen.isIdleComposer)
        XCTAssertTrue(screen.requestOptions.isEmpty)
    }

    func testWorkingScreenIsNeitherIdleNorRequesting() throws {
        let screen = try ClaudeTerminalScreen.parse(fixture("working-screen"))

        XCTAssertFalse(screen.isIdleComposer)
        XCTAssertTrue(screen.requestOptions.isEmpty)
    }

    func testFingerprintIgnoresAnsiStylingAndTrailingWhitespace() throws {
        let plain = "╭────╮\n│ Do you want to proceed? │\n│ ❯ 1. Yes │\n│   2. No │\n╰────╯"
        let styled = "╭────╮\n│ Do you want to proceed?   │\n"
            + "│ \u{1B}[7m❯ 1. Yes\u{1B}[0m   │\n│   2. No │\n╰────╯   "

        XCTAssertEqual(
            try ClaudeTerminalScreen.parse(plain).fingerprint,
            try ClaudeTerminalScreen.parse(styled).fingerprint
        )
    }

    func testFingerprintChangesWhenThePromptChanges() throws {
        let first = try ClaudeTerminalScreen.parse(fixture("permission-screen"))
        let second = try ClaudeTerminalScreen.parse(fixture("question-screen"))

        XCTAssertNotEqual(first.fingerprint, second.fingerprint)
    }

    // MARK: - Execution safety

    func testExecutorRejectsChangedPromptBeforeSendingKeys() async throws {
        let terminal = FakeClaudeTerminal(captured: try fixtureText("working-screen"))
        let executor = ClaudeManagedRequestExecutor()

        do {
            try await executor.resolve(
                decision: .accept,
                expectedFingerprint: "old",
                runtime: managed,
                terminal: terminal
            )
            XCTFail("expected a stale prompt to be rejected")
        } catch {
            XCTAssertEqual(error as? ClaudeTerminalError, .stalePrompt)
        }

        let sent = await terminal.sentInputs()
        XCTAssertTrue(sent.isEmpty)
    }

    func testExecutorAcceptsOnlyWhenFingerprintStillMatches() async throws {
        let screen = try ClaudeTerminalScreen.parse(fixture("permission-screen"))
        let terminal = FakeClaudeTerminal(captured: try fixtureText("permission-screen"))
        let executor = ClaudeManagedRequestExecutor()

        try await executor.resolve(
            decision: .accept,
            expectedFingerprint: screen.fingerprint,
            runtime: managed,
            terminal: terminal
        )

        let sent = await terminal.sentInputs()
        XCTAssertEqual(sent, ["Yes"])
    }

    func testDeclineSelectsTheVisibleNegativeLabel() async throws {
        let screen = try ClaudeTerminalScreen.parse(fixture("permission-screen"))
        let terminal = FakeClaudeTerminal(captured: try fixtureText("permission-screen"))
        let executor = ClaudeManagedRequestExecutor()

        try await executor.resolve(
            decision: .decline,
            expectedFingerprint: screen.fingerprint,
            runtime: managed,
            terminal: terminal
        )

        let sent = await terminal.sentInputs()
        XCTAssertEqual(sent, ["No"])
    }

    func testAcceptForSessionSelectsTheDontAskAgainLabel() async throws {
        let screen = try ClaudeTerminalScreen.parse(fixture("permission-screen"))
        let terminal = FakeClaudeTerminal(captured: try fixtureText("permission-screen"))
        let executor = ClaudeManagedRequestExecutor()

        try await executor.resolve(
            decision: .acceptForSession,
            expectedFingerprint: screen.fingerprint,
            runtime: managed,
            terminal: terminal
        )

        let sent = await terminal.sentInputs()
        XCTAssertEqual(sent, ["Yes, and don't ask again"])
    }

    func testChoiceMustMatchAVisibleLabelExactly() async throws {
        let screen = try ClaudeTerminalScreen.parse(fixture("question-screen"))
        let terminal = FakeClaudeTerminal(captured: try fixtureText("question-screen"))
        let executor = ClaudeManagedRequestExecutor()

        do {
            try await executor.resolve(
                decision: .choices(["Developement"]),
                expectedFingerprint: screen.fingerprint,
                runtime: managed,
                terminal: terminal
            )
            XCTFail("expected an unmatched label to be rejected")
        } catch {
            XCTAssertEqual(error as? ClaudeTerminalError, .stalePrompt)
        }

        let sent = await terminal.sentInputs()
        XCTAssertTrue(sent.isEmpty)
    }

    func testTextDecisionIsPastedLiterallyOnAnIdleComposer() async throws {
        let screen = try ClaudeTerminalScreen.parse(fixture("idle-screen"))
        let terminal = FakeClaudeTerminal(captured: try fixtureText("idle-screen"))
        let executor = ClaudeManagedRequestExecutor()

        try await executor.resolve(
            decision: .text("looks good"),
            expectedFingerprint: screen.fingerprint,
            runtime: managed,
            terminal: terminal
        )

        let sent = await terminal.sentInputs()
        XCTAssertEqual(sent, ["looks good"])
        let submits = await terminal.submitCount()
        XCTAssertEqual(submits, 1)
    }

    func testDecisionAgainstAWorkingScreenSendsNothing() async throws {
        let screen = try ClaudeTerminalScreen.parse(fixture("working-screen"))
        let terminal = FakeClaudeTerminal(captured: try fixtureText("working-screen"))
        let executor = ClaudeManagedRequestExecutor()

        do {
            try await executor.resolve(
                decision: .accept,
                expectedFingerprint: screen.fingerprint,
                runtime: managed,
                terminal: terminal
            )
            XCTFail("expected a busy screen to reject a decision")
        } catch {
            XCTAssertEqual(error as? ClaudeTerminalError, .stalePrompt)
        }

        let sent = await terminal.sentInputs()
        XCTAssertTrue(sent.isEmpty)
    }

    func testExecutorRefusesAPaneFromAnotherSession() async throws {
        let screen = try ClaudeTerminalScreen.parse(fixture("permission-screen"))
        let terminal = FakeClaudeTerminal(
            captured: try fixtureText("permission-screen"),
            aliveSessionName: "agenthub-other"
        )
        let executor = ClaudeManagedRequestExecutor()

        do {
            try await executor.resolve(
                decision: .accept,
                expectedFingerprint: screen.fingerprint,
                runtime: managed,
                terminal: terminal
            )
            XCTFail("expected a dead managed session to be rejected")
        } catch {
            XCTAssertEqual(error as? ClaudeTerminalError, .sessionNotFound)
        }

        let sent = await terminal.sentInputs()
        XCTAssertTrue(sent.isEmpty)
    }

    // MARK: - Helpers

    private func fixture(_ name: String) throws -> String {
        try fixtureText(name)
    }

    private func fixtureText(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Claude/\(name).txt")
        return try String(contentsOf: url, encoding: .utf8)
    }
}

actor FakeClaudeTerminal: ClaudeTerminalControlling {
    private let captured: String
    private let aliveSessionName: String?
    private var inputs: [String] = []
    private var submits = 0

    init(captured: String, aliveSessionName: String? = nil) {
        self.captured = captured
        self.aliveSessionName = aliveSessionName
    }

    func sentInputs() -> [String] { inputs }
    func submitCount() -> Int { submits }

    func launch(
        name: String,
        claudeSessionID: UUID,
        title: String,
        cwd: String,
        model: String?
    ) async throws -> ClaudeManagedRuntime {
        ClaudeManagedRuntime(sessionName: name, paneID: "%3")
    }

    func listManaged() async throws -> [ClaudeManagedRuntime] { [] }

    func capture(paneID: String) async throws -> String { captured }

    func pasteLiteral(_ text: String, paneID: String) async throws {
        inputs.append(text)
    }

    func submit(paneID: String) async throws { submits += 1 }

    func select(sessionName: String) async throws {}

    func attach(sessionName: String) async throws {}

    func isAlive(sessionName: String) async throws -> Bool {
        guard let aliveSessionName else { return true }
        return aliveSessionName == sessionName
    }
}
