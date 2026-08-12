import Foundation
import XCTest
@testable import AgentHubClaude

final class CodexBarInstallerTests: XCTestCase {
    func testInstallerUsesExactHomebrewCaskCommandThenValidates() async throws {
        let runner = RecordingInstallRunner()
        let validator = RecordingValidator()
        let installer = CodexBarInstaller(
            brewPath: "/opt/homebrew/bin/brew",
            run: runner.run,
            validate: validator.validate
        )

        try await installer.install()

        let calls = await runner.calls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.executable, "/opt/homebrew/bin/brew")
        XCTAssertEqual(calls.first?.arguments, ["install", "--cask", "codexbar"])
        let validated = await validator.wasCalled()
        XCTAssertTrue(validated)
    }

    func testInstallerNeverRequestsSudoOrUsesAShell() async throws {
        let runner = RecordingInstallRunner()
        let installer = CodexBarInstaller(
            brewPath: "/opt/homebrew/bin/brew",
            run: runner.run,
            validate: RecordingValidator().validate
        )

        try await installer.install()

        let calls = await runner.calls()
        let executables = calls.map(\.executable)
        XCTAssertFalse(executables.contains { $0.hasSuffix("sudo") })
        XCTAssertFalse(executables.contains { $0.hasSuffix("sh") || $0.hasSuffix("bash") })
        XCTAssertFalse(calls.flatMap(\.arguments).contains { $0.contains("&&") || $0.contains("|") })
    }

    func testMissingHomebrewFailsWithoutRunningAnything() async {
        let runner = RecordingInstallRunner()
        let installer = CodexBarInstaller(
            brewPath: nil,
            run: runner.run,
            validate: RecordingValidator().validate
        )

        do {
            try await installer.install()
            XCTFail("expected a missing package manager error")
        } catch {
            XCTAssertEqual(error as? CodexBarInstallerError, .packageManagerUnavailable)
        }
        let calls = await runner.calls()
        XCTAssertTrue(calls.isEmpty)
    }

    func testFailedInstallDoesNotClaimSuccessAndSkipsValidation() async {
        let runner = RecordingInstallRunner(exitStatus: 1)
        let validator = RecordingValidator()
        let installer = CodexBarInstaller(
            brewPath: "/opt/homebrew/bin/brew",
            run: runner.run,
            validate: validator.validate
        )

        do {
            try await installer.install()
            XCTFail("expected an installation failure")
        } catch {
            XCTAssertEqual(error as? CodexBarInstallerError, .installationFailed)
        }
        let validated = await validator.wasCalled()
        XCTAssertFalse(validated)
    }

    func testResolveBrewOnlyAcceptsKnownAbsolutePaths() {
        XCTAssertEqual(
            CodexBarInstaller.resolveBrew(isExecutable: { $0 == "/opt/homebrew/bin/brew" }),
            "/opt/homebrew/bin/brew"
        )
        XCTAssertEqual(
            CodexBarInstaller.resolveBrew(isExecutable: { $0 == "/usr/local/bin/brew" }),
            "/usr/local/bin/brew"
        )
        XCTAssertNil(CodexBarInstaller.resolveBrew(isExecutable: { _ in false }))
        // A brew somewhere else entirely is not trusted.
        XCTAssertNil(CodexBarInstaller.resolveBrew(isExecutable: { $0 == "/tmp/evil/brew" }))
    }
}

private actor RecordingInstallRunner {
    private let exitStatus: Int32
    private var recorded: [ClaudeCommand] = []

    init(exitStatus: Int32 = 0) {
        self.exitStatus = exitStatus
    }

    func calls() -> [ClaudeCommand] { recorded }

    @Sendable
    nonisolated func run(_ command: ClaudeCommand) async throws -> QuotaCommandResult {
        await record(command)
    }

    private func record(_ command: ClaudeCommand) -> QuotaCommandResult {
        recorded.append(command)
        return QuotaCommandResult(
            standardOutput: "",
            standardError: exitStatus == 0 ? "" : "cask not found",
            exitStatus: exitStatus
        )
    }
}

private actor RecordingValidator {
    private var called = false

    func wasCalled() -> Bool { called }

    @Sendable
    nonisolated func validate() async throws {
        await mark()
    }

    private func mark() { called = true }
}
