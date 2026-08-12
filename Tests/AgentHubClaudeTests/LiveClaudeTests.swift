import Foundation
import XCTest
import AgentHubCore
@testable import AgentHubClaude

/// Checks that run against the Claude installed on this machine.
///
/// Every test here is skipped unless its own environment flag is set, so the
/// default suite never touches real Claude state or consumes quota.
final class LiveClaudeTests: XCTestCase {
    private var isSmokeEnabled: Bool {
        ProcessInfo.processInfo.environment["AGENTHUB_LIVE_CLAUDE_SMOKE"] == "1"
    }

    private var isPromptEnabled: Bool {
        ProcessInfo.processInfo.environment["AGENTHUB_LIVE_CLAUDE_PROMPT"] == "1"
    }

    func testClaudeVersionIsReportedWithoutExposingAuthData() throws {
        try XCTSkipUnless(isSmokeEnabled, "set AGENTHUB_LIVE_CLAUDE_SMOKE=1 to run")
        let claude = try XCTUnwrap(locate("claude"), "claude executable not found")

        let output = try run(claude, ["--version"])

        XCTAssertTrue(output.contains("."), "expected a version string")
        // A version probe must never surface credentials.
        for secret in ["sk-ant", "ANTHROPIC_API_KEY", "Bearer "] {
            XCTAssertFalse(output.contains(secret))
        }
    }

    func testHookInstallAndUninstallRoundTripOnATemporaryFile() throws {
        try XCTSkipUnless(isSmokeEnabled, "set AGENTHUB_LIVE_CLAUDE_SMOKE=1 to run")
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agenthub-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A temporary settings file: the user's real settings are never touched.
        let settings = directory.appendingPathComponent("settings.json")
        let installer = ClaudeHookInstaller(
            settingsURL: settings,
            executableURL: directory.appendingPathComponent("agenthub-claude-hook")
        )

        try installer.install()
        XCTAssertTrue(try installer.status().available)
        try installer.uninstall()
        XCTAssertFalse(try installer.status().available)
    }

    func testTmuxSupportsTheCapabilitiesManagedSessionsNeed() throws {
        try XCTSkipUnless(isSmokeEnabled, "set AGENTHUB_LIVE_CLAUDE_SMOKE=1 to run")
        let tmux = try XCTUnwrap(locate("tmux"), "tmux executable not found")

        XCTAssertTrue(try run(tmux, ["-V"]).contains("tmux"))
        // `load-buffer -` is how a prompt reaches Claude without ever appearing
        // in process arguments.
        XCTAssertTrue(try run(tmux, ["list-commands"]).contains("load-buffer"))
        XCTAssertTrue(try run(tmux, ["list-commands"]).contains("paste-buffer"))
    }

    func testManagedPromptRoundTrip() throws {
        try XCTSkipUnless(
            isPromptEnabled,
            "set AGENTHUB_LIVE_CLAUDE_PROMPT=1 to run; this CONSUMES Claude quota"
        )
        throw XCTSkip(
            "Interactive managed prompt delivery is verified manually; see docs/claude-testing.md"
        )
    }

    // MARK: - Helpers

    private func locate(_ name: String) -> URL? {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/\(name)"),
            URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"),
            URL(fileURLWithPath: "/usr/local/bin/\(name)"),
            URL(fileURLWithPath: "/usr/bin/\(name)"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func run(_ executable: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
