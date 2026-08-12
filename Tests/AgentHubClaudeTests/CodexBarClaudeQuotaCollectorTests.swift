import Foundation
import XCTest
import AgentHubCore
@testable import AgentHubClaude

final class CodexBarClaudeQuotaCollectorTests: XCTestCase {
    private let appHelper = "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI"

    // MARK: - Discovery

    func testAppHelperWinsOverPathAndMapsAllClaudeWindows() async throws {
        let runner = RecordingQuotaRunner(standardOutput: try fixture("codexbar-usage"))
        let collector = CodexBarClaudeQuotaCollector(
            location: CodexBarLocation.discover(
                isExecutable: { [self.appHelper, "/opt/homebrew/bin/codexbar"].contains($0) },
                pathEnvironment: "/opt/homebrew/bin"
            ),
            run: runner.run,
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        let snapshot = try await collector.collect()

        XCTAssertEqual(snapshot.executablePath, appHelper)
        XCTAssertEqual(snapshot.windows.compactMap(\.windowID), ["session", "weekly", "sonnet"])
        XCTAssertTrue(snapshot.windows.allSatisfy { $0.accountID == "user@example.com" })
        XCTAssertTrue(snapshot.windows.allSatisfy { $0.plan == "Pro" })
        XCTAssertTrue(snapshot.windows.allSatisfy { $0.provider == .claude })
        XCTAssertTrue(snapshot.windows.allSatisfy { $0.source == "codexbar" })
    }

    func testPathIsUsedWhenTheAppHelperIsAbsent() async throws {
        let runner = RecordingQuotaRunner(standardOutput: try fixture("codexbar-usage"))
        let collector = CodexBarClaudeQuotaCollector(
            location: CodexBarLocation.discover(
                isExecutable: { $0 == "/opt/homebrew/bin/codexbar" },
                pathEnvironment: "/usr/bin:/opt/homebrew/bin"
            ),
            run: runner.run,
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        let snapshot = try await collector.collect()
        XCTAssertEqual(snapshot.executablePath, "/opt/homebrew/bin/codexbar")
    }

    func testMissingBinaryReportsUnavailableSourceWithoutRunningAnything() async {
        let runner = RecordingQuotaRunner(standardOutput: "")
        let collector = CodexBarClaudeQuotaCollector(
            location: CodexBarLocation.discover(
                isExecutable: { _ in false },
                pathEnvironment: "/usr/bin"
            ),
            run: runner.run,
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        do {
            _ = try await collector.collect()
            XCTFail("expected an unavailable source")
        } catch {
            XCTAssertEqual(error as? ClaudeQuotaError, .sourceUnavailable)
        }
        let calls = await runner.calls()
        XCTAssertTrue(calls.isEmpty)
    }

    // MARK: - Invocation

    func testInvocationUsesMachineReadableClaudeOnlyArguments() async throws {
        let runner = RecordingQuotaRunner(standardOutput: try fixture("codexbar-usage"))
        _ = try await makeCollector(runner: runner).collect()

        let calls = await runner.calls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.executable, appHelper)
        XCTAssertEqual(
            calls.first?.arguments,
            [
                "usage",
                "--provider", "claude",
                "--source", "auto",
                "--format", "json",
                "--json-only",
                "--timeout", "10",
            ]
        )
    }

    // MARK: - Mapping

    func testWindowsCarrySourceTimestampAndDistinctIdentities() async throws {
        let runner = RecordingQuotaRunner(standardOutput: try fixture("codexbar-usage"))
        let snapshot = try await makeCollector(runner: runner).collect()

        let session = try XCTUnwrap(snapshot.windows.first { $0.windowID == "session" })
        let sonnet = try XCTUnwrap(snapshot.windows.first { $0.windowID == "sonnet" })

        XCTAssertEqual(session.windowDuration, 18_000)
        XCTAssertEqual(sonnet.windowDuration, 18_000)
        XCTAssertNotEqual(session.id, sonnet.id)
        XCTAssertEqual(session.usedPercent, 42.5)
        XCTAssertEqual(session.label, "Session")
        // The source timestamp is authoritative so staleness reflects when the
        // provider produced the data, not when AgentHub asked for it.
        XCTAssertEqual(session.fetchedAt, ISO8601DateFormatter().date(from: "2026-08-12T04:00:00Z"))
    }

    func testPartialSnapshotKeepsValidWindowsAndDropsInvalidOnes() async throws {
        let runner = RecordingQuotaRunner(standardOutput: try fixture("codexbar-partial"))
        let snapshot = try await makeCollector(runner: runner).collect()

        XCTAssertEqual(snapshot.windows.compactMap(\.windowID), ["session"])
        XCTAssertTrue(snapshot.isPartial)
    }

    func testWrongProviderIsRejected() async throws {
        let runner = RecordingQuotaRunner(standardOutput: """
        {"provider":"codex","identity":{"account":"a"},"usage":{"primary":
        {"id":"session","used_percent":1,"window_seconds":100,
        "resets_at":"2026-08-12T09:00:00Z"}}}
        """)

        await assertCollectFails(makeCollector(runner: runner), with: .malformedSnapshot)
    }

    func testSnapshotWithoutAnyValidWindowIsRejected() async throws {
        let runner = RecordingQuotaRunner(standardOutput: """
        {"provider":"claude","identity":{"account":"user@example.com"},
        "usage":{"primary":{"id":"session","used_percent":900,
        "window_seconds":100,"resets_at":"2026-08-12T09:00:00Z"}}}
        """)

        await assertCollectFails(makeCollector(runner: runner), with: .malformedSnapshot)
    }

    func testSnapshotWithoutIdentityIsRejected() async throws {
        let runner = RecordingQuotaRunner(standardOutput: """
        {"provider":"claude","usage":{"primary":{"id":"session",
        "used_percent":10,"window_seconds":100,
        "resets_at":"2026-08-12T09:00:00Z"}}}
        """)

        await assertCollectFails(makeCollector(runner: runner), with: .malformedSnapshot)
    }

    // MARK: - Failure handling

    func testTimeoutAndAuthenticationErrorsContainNoRawProviderText() async {
        let timeout = RecordingQuotaRunner(standardOutput: "", error: .timeout)
        await assertCollectFails(makeCollector(runner: timeout), with: .timeout)

        let auth = RecordingQuotaRunner(
            standardOutput: "",
            standardError: "token expired for user@example.com: secret-token-abc",
            exitStatus: 3
        )
        do {
            _ = try await makeCollector(runner: auth).collect()
            XCTFail("expected a source failure")
        } catch {
            XCTAssertEqual(error as? ClaudeQuotaError, .authenticationRequired)
            XCTAssertFalse(String(describing: error).contains("secret-token-abc"))
            XCTAssertFalse(String(describing: error).contains("user@example.com"))
        }
    }

    func testNonJSONOutputIsRejectedRatherThanTextParsed() async {
        let runner = RecordingQuotaRunner(standardOutput: "Claude ▓▓▓░░ 42% · resets 09:00")
        await assertCollectFails(makeCollector(runner: runner), with: .malformedSnapshot)
    }

    func testOversizedOutputIsRejected() async {
        let runner = RecordingQuotaRunner(
            standardOutput: String(repeating: "x", count: 1_024 * 1_024 + 1)
        )
        await assertCollectFails(makeCollector(runner: runner), with: .malformedSnapshot)
    }

    // MARK: - Helpers

    private func makeCollector(runner: RecordingQuotaRunner) -> CodexBarClaudeQuotaCollector {
        CodexBarClaudeQuotaCollector(
            location: CodexBarLocation(executablePath: appHelper),
            run: runner.run,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
    }

    private func assertCollectFails(
        _ collector: CodexBarClaudeQuotaCollector,
        with expected: ClaudeQuotaError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await collector.collect()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ClaudeQuotaError, expected, file: file, line: line)
        }
    }

    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Claude/\(name).json")
        return try String(contentsOf: url, encoding: .utf8)
    }
}

private actor RecordingQuotaRunner {
    private let standardOutput: String
    private let standardError: String
    private let exitStatus: Int32
    private let error: ClaudeQuotaError?
    private var recorded: [ClaudeCommand] = []

    init(
        standardOutput: String,
        standardError: String = "",
        exitStatus: Int32 = 0,
        error: ClaudeQuotaError? = nil
    ) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitStatus = exitStatus
        self.error = error
    }

    func calls() -> [ClaudeCommand] { recorded }

    @Sendable
    nonisolated func run(_ command: ClaudeCommand) async throws -> QuotaCommandResult {
        try await record(command)
    }

    private func record(_ command: ClaudeCommand) throws -> QuotaCommandResult {
        recorded.append(command)
        if let error { throw error }
        return QuotaCommandResult(
            standardOutput: standardOutput,
            standardError: standardError,
            exitStatus: exitStatus
        )
    }
}
