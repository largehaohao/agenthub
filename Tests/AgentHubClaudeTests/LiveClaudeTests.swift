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

    /// The wrapper is a shell string, so unit tests can only prove its shape.
    /// This actually executes it to prove the contract that matters: AgentHub
    /// receives the payload, and the user's own status line receives the
    /// identical bytes and still owns the display.
    func testGeneratedStatusLineCommandFeedsBothReporterAndUserCommand() throws {
        try XCTSkipUnless(isSmokeEnabled, "set AGENTHUB_LIVE_CLAUDE_SMOKE=1 to run")
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agenthub-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Stand-ins for the packaged reporter and the user's own status line.
        let received = directory.appendingPathComponent("received.json")
        let reporter = try makeScript(
            at: directory.appendingPathComponent("reporter"),
            body: "cat > '\(received.path)'"
        )
        let userScript = try makeScript(
            at: directory.appendingPathComponent("user-statusline"),
            body: "payload=$(cat); printf 'user-saw:%s' \"$payload\""
        )

        let settings = directory.appendingPathComponent("settings.json")
        try Data("""
        {"statusLine":{"type":"command","command":"sh \(userScript.path)"}}
        """.utf8).write(to: settings)

        let installer = ClaudeStatusLineInstaller(
            settingsURL: settings,
            executableURL: reporter
        )
        try installer.install()

        let command = try XCTUnwrap(installedCommand(in: settings))
        let payload = """
        {"session_id":"live","rate_limits":{"five_hour":\
        {"used_percentage":33,"resets_at":"2026-08-12T09:00:00Z"}}}
        """
        let stdout = try runShell(command, stdin: payload)

        // The user's command ran and its output is what Claude would render.
        XCTAssertTrue(stdout.contains("user-saw:"))
        XCTAssertTrue(stdout.contains("\"used_percentage\":33"))
        // AgentHub received the same payload and printed nothing itself.
        let delivered = try Data(contentsOf: received)
        XCTAssertEqual(String(decoding: delivered, as: UTF8.self), payload)
        let report = try ClaudeStatusLineDecoder().decode(delivered)
        XCTAssertEqual(report.windows.first?.usedPercent, 33)
    }

    /// A broken or missing reporter must never break the user's status line.
    func testUserStatusLineSurvivesAFailingReporter() throws {
        try XCTSkipUnless(isSmokeEnabled, "set AGENTHUB_LIVE_CLAUDE_SMOKE=1 to run")
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agenthub-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let reporter = try makeScript(
            at: directory.appendingPathComponent("reporter"),
            body: "exit 9"
        )
        let userScript = try makeScript(
            at: directory.appendingPathComponent("user-statusline"),
            body: "cat >/dev/null; printf 'still-here'"
        )
        let settings = directory.appendingPathComponent("settings.json")
        try Data("""
        {"statusLine":{"type":"command","command":"sh \(userScript.path)"}}
        """.utf8).write(to: settings)

        try ClaudeStatusLineInstaller(
            settingsURL: settings,
            executableURL: reporter
        ).install()

        let command = try XCTUnwrap(installedCommand(in: settings))
        XCTAssertEqual(try runShell(command, stdin: "{}"), "still-here")
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

    private func installedCommand(in settings: URL) throws -> String? {
        let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: settings))
        return ((object as? [String: Any])?["statusLine"] as? [String: Any])?["command"] as? String
    }

    private func makeScript(at url: URL, body: String) throws -> URL {
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
        return url
    }

    /// Runs a status-line command exactly as Claude Code would: through `sh`
    /// with the payload on stdin.
    private func runShell(_ command: String, stdin: String) throws -> String {
        let process = Process()
        let output = Pipe()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = output
        process.standardError = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

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
