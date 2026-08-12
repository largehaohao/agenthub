import Foundation
import XCTest
@testable import AgentHubClaude

final class ClaudeTerminalRuntimeTests: XCTestCase {
    private let claudeID = UUID(uuidString: "A1B2C3D4-0000-0000-0000-00000000FFFF")!

    func testLaunchUsesFixedSessionIDAndNeverPutsPromptInArguments() async throws {
        let runner = RecordingCommandRunner(output: "agenthub-a1b2c3d4\t%3")
        let runtime = makeRuntime(runner)

        _ = try await runtime.launch(
            name: "agenthub-a1b2c3d4",
            claudeSessionID: claudeID,
            title: "Fix tests",
            cwd: "/tmp/repo",
            model: "sonnet"
        )

        let calls = await runner.calls()
        let arguments = try XCTUnwrap(calls.first?.arguments)
        let sessionIDIndex = try XCTUnwrap(arguments.firstIndex(of: "--session-id"))
        XCTAssertEqual(arguments[sessionIDIndex + 1], claudeID.uuidString)

        let modelIndex = try XCTUnwrap(arguments.firstIndex(of: "--model"))
        XCTAssertEqual(arguments[modelIndex + 1], "sonnet")

        let everyArgument = calls.flatMap(\.arguments)
        XCTAssertFalse(everyArgument.contains("Build it"))
        XCTAssertTrue(calls.contains { $0.executable == "/usr/bin/osascript" })
    }

    func testLaunchOmitsModelFlagWhenUnspecified() async throws {
        let runner = RecordingCommandRunner(output: "agenthub-a1b2c3d4\t%3")
        let runtime = makeRuntime(runner)

        _ = try await runtime.launch(
            name: "agenthub-a1b2c3d4",
            claudeSessionID: claudeID,
            title: "Fix tests",
            cwd: "/tmp/repo",
            model: nil
        )

        let calls = await runner.calls()
        let arguments = try XCTUnwrap(calls.first?.arguments)
        XCTAssertFalse(arguments.contains("--model"))
    }

    func testLaunchNeverBuildsAShellCommandFromUserValues() async throws {
        let runner = RecordingCommandRunner(output: "agenthub-a1b2c3d4\t%3")
        let runtime = makeRuntime(runner)

        _ = try await runtime.launch(
            name: "agenthub-a1b2c3d4",
            claudeSessionID: claudeID,
            title: "Fix tests; rm -rf /",
            cwd: "/tmp/repo",
            model: nil
        )

        let calls = await runner.calls()
        for call in calls {
            XCTAssertFalse(
                ["/bin/sh", "/bin/bash", "/bin/zsh"].contains(call.executable),
                "runtime must invoke executables directly rather than through a shell"
            )
        }

        // The title reaches Claude as one argument value, never spliced into a
        // longer string where `;` could separate a second command.
        let create = try XCTUnwrap(calls.first)
        XCTAssertTrue(create.arguments.contains("Fix tests; rm -rf /"))
        XCTAssertFalse(create.arguments.contains { $0.hasPrefix("claude ") })
    }

    func testListManagedAcceptsOnlyAgentHubPrefixedSessions() async throws {
        let runner = RecordingCommandRunner(output: """
        agenthub-a1b2c3d4\t%3
        personal-work\t%7
        agenthub-99887766\t%11
        """)
        let runtime = makeRuntime(runner)

        let managed = try await runtime.listManaged()

        XCTAssertEqual(managed.map(\.sessionName), ["agenthub-a1b2c3d4", "agenthub-99887766"])
        XCTAssertEqual(managed.map(\.paneID), ["%3", "%11"])
    }

    func testListManagedIgnoresMalformedRows() async throws {
        let runner = RecordingCommandRunner(output: """
        agenthub-a1b2c3d4\t%3
        agenthub-missing-pane
        \t%9
        """)
        let runtime = makeRuntime(runner)

        let managed = try await runtime.listManaged()

        XCTAssertEqual(managed.map(\.sessionName), ["agenthub-a1b2c3d4"])
    }

    func testPasteLiteralSendsTextThroughBufferStdinNotArguments() async throws {
        let runner = RecordingCommandRunner()
        let runtime = makeRuntime(runner)

        try await runtime.pasteLiteral("Build it", paneID: "%3")

        let calls = await runner.calls()
        XCTAssertFalse(calls.flatMap(\.arguments).contains("Build it"))
        let standardInput = await runner.standardInputValues()
        XCTAssertEqual(standardInput, ["Build it"])

        let load = try XCTUnwrap(calls.first { $0.arguments.contains("load-buffer") })
        XCTAssertTrue(load.arguments.contains("-"))
        let paste = try XCTUnwrap(calls.first { $0.arguments.contains("paste-buffer") })
        XCTAssertTrue(paste.arguments.contains("-d"))
        XCTAssertTrue(paste.arguments.contains("%3"))
    }

    func testSubmitSendsOnlyAnEnterKey() async throws {
        let runner = RecordingCommandRunner()
        let runtime = makeRuntime(runner)

        try await runtime.submit(paneID: "%3")

        let calls = await runner.calls()
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.executable, "/opt/homebrew/bin/tmux")
        XCTAssertTrue(call.arguments.contains("send-keys"))
        XCTAssertTrue(call.arguments.contains("Enter"))
    }

    func testCaptureReturnsPaneContents() async throws {
        let runner = RecordingCommandRunner(output: "› \n")
        let runtime = makeRuntime(runner)

        let captured = try await runtime.capture(paneID: "%3")

        XCTAssertEqual(captured, "› \n")
        let calls = await runner.calls()
        let call = try XCTUnwrap(calls.first)
        XCTAssertTrue(call.arguments.contains("capture-pane"))
        XCTAssertTrue(call.arguments.contains("%3"))
    }

    func testIsAliveReflectsTmuxExitStatus() async throws {
        let alive = makeRuntime(RecordingCommandRunner(output: "agenthub-a1b2c3d4\t%3"))
        let isAlive = try await alive.isAlive(sessionName: "agenthub-a1b2c3d4")
        XCTAssertTrue(isAlive)

        let gone = makeRuntime(RecordingCommandRunner(output: "personal-work\t%7"))
        let isGone = try await gone.isAlive(sessionName: "agenthub-a1b2c3d4")
        XCTAssertFalse(isGone)
    }

    func testAttachPassesSessionNameThroughArgumentsNotScriptText() async throws {
        let runner = RecordingCommandRunner()
        let runtime = makeRuntime(runner)

        try await runtime.attach(sessionName: "agenthub-a1b2c3d4")

        let calls = await runner.calls()
        let call = try XCTUnwrap(calls.first { $0.executable == "/usr/bin/osascript" })
        // The script itself is static; the session name arrives via argv so a
        // crafted name cannot be interpolated into AppleScript.
        let scriptIndex = try XCTUnwrap(call.arguments.firstIndex(of: "-e"))
        XCTAssertFalse(call.arguments[scriptIndex + 1].contains("agenthub-a1b2c3d4"))
        XCTAssertTrue(call.arguments.contains("agenthub-a1b2c3d4"))
    }

    private func makeRuntime(_ runner: RecordingCommandRunner) -> TmuxClaudeTerminalRuntime {
        TmuxClaudeTerminalRuntime(
            claudeExecutable: URL(fileURLWithPath: "/Users/tester/.local/bin/claude"),
            tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
            osascriptExecutable: URL(fileURLWithPath: "/usr/bin/osascript"),
            run: { command in try await runner.run(command) }
        )
    }
}

actor RecordingCommandRunner {
    private var recorded: [ClaudeCommand] = []
    private let output: String

    init(output: String = "") {
        self.output = output
    }

    func run(_ command: ClaudeCommand) throws -> ClaudeCommandResult {
        recorded.append(command)
        return ClaudeCommandResult(standardOutput: output, exitStatus: 0)
    }

    func calls() -> [ClaudeCommand] { recorded }

    func standardInputValues() -> [String] {
        recorded.compactMap(\.standardInput)
    }
}
