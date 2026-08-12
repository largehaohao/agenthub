import Foundation
import XCTest
import AgentHubCore
@testable import AgentHubIPC

/// End-to-end delivery: the real packaged reporter binary, a real Unix socket,
/// and a real daemon server. This is the only test that proves the helper
/// actually reaches a daemon rather than merely building the right bytes.
///
/// Gated because it requires `swift build --product agenthub-claude-statusline`
/// to have produced the binary.
final class ClaudeStatusLineDeliveryTests: XCTestCase {
    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["AGENTHUB_LIVE_CLAUDE_SMOKE"] == "1"
    }

    func testReporterBinaryDeliversQuotaPayloadToARealDaemon() async throws {
        try XCTSkipUnless(isEnabled, "set AGENTHUB_LIVE_CLAUDE_SMOKE=1 to run")
        let reporter = try XCTUnwrap(builtReporter(), "build agenthub-claude-statusline first")

        let path = temporarySocketPath()
        let received = ReceivedCommands()
        let server = try await UnixDaemonServer.bind(path: path) { command in
            await received.record(command)
            return .completed
        }
        defer { Task { await server.stop() } }

        let payload = """
        {"session_id":"live","rate_limits":{"five_hour":\
        {"used_percentage":77,"resets_at":"2026-08-12T09:00:00Z"}}}
        """
        let status = try runReporter(reporter, socket: path, stdin: payload)
        XCTAssertEqual(status, 0, "the reporter must never fail a status line")

        // Give the one-shot helper a moment to complete its send.
        try await Task.sleep(for: .milliseconds(600))

        let commands = await received.all()
        XCTAssertEqual(commands.count, 1)
        guard case .ingestProviderHook(let envelope) = commands.first else {
            return XCTFail("expected a provider hook envelope")
        }
        XCTAssertEqual(envelope.provider, .claude)
        XCTAssertEqual(String(decoding: envelope.rawJSON, as: UTF8.self), payload)
        // The status line reports usage, not process ancestry.
        XCTAssertTrue(envelope.ancestors.isEmpty)
    }

    func testReporterExitsCleanlyWhenNoDaemonIsListening() throws {
        try XCTSkipUnless(isEnabled, "set AGENTHUB_LIVE_CLAUDE_SMOKE=1 to run")
        let reporter = try XCTUnwrap(builtReporter(), "build agenthub-claude-statusline first")

        let status = try runReporter(
            reporter,
            socket: "/tmp/agenthub-nonexistent-\(UUID().uuidString).sock",
            stdin: "{\"session_id\":\"x\",\"rate_limits\":{}}"
        )

        // An absent daemon must never break the user's status line.
        XCTAssertEqual(status, 0)
    }

    // MARK: - Helpers

    private func builtReporter() -> URL? {
        // Tests run from the package root's .build directory.
        let candidates = ["debug", "release"].map {
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/\($0)/agenthub-claude-statusline")
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func runReporter(_ binary: URL, socket: String, stdin: String) throws -> Int32 {
        let process = Process()
        let input = Pipe()
        process.executableURL = binary
        process.environment = ["AGENTHUB_SOCKET": socket]
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func temporarySocketPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("agenthub-e2e-\(UUID().uuidString.prefix(8)).sock")
            .path
    }
}

private actor ReceivedCommands {
    private var commands: [DaemonCommand] = []

    func record(_ command: DaemonCommand) { commands.append(command) }
    func all() -> [DaemonCommand] { commands }
}
