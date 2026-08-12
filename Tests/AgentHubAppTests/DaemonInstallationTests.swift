import Foundation
import XCTest
@testable import AgentHubApp

final class DaemonInstallationTests: XCTestCase {
    func testInstallerUsesUserLaunchAgentsOnly() {
        let paths = DaemonInstallation.paths(
            home: URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        )

        XCTAssertEqual(
            paths.plist.path,
            "/Users/tester/Library/LaunchAgents/com.agenthub.daemon.plist"
        )
        XCTAssertEqual(
            paths.executable.path,
            "/Users/tester/Library/Application Support/AgentHub/bin/agenthubd"
        )
    }

    func testPlistDoesNotRequestRoot() throws {
        let plist = DaemonInstallation.renderPlist(
            executable: "/Applications/AgentHub.app/Contents/Helpers/agenthubd",
            pathEnvironment: "/usr/bin:/bin"
        )

        XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertNil(plist["UserName"])
        XCTAssertNil(plist["GroupName"])
        XCTAssertEqual(
            plist["ProgramArguments"] as? [String],
            ["/Applications/AgentHub.app/Contents/Helpers/agenthubd"]
        )
    }

    func testRenderedPlistIsValidPropertyList() throws {
        let plist = DaemonInstallation.renderPlist(
            executable: "/Users/tester/Library/Application Support/AgentHub/bin/agenthubd",
            pathEnvironment: "/opt/homebrew/bin:/usr/bin:/bin"
        )

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(
            plist["WorkingDirectory"] as? String,
            "/Users/tester/Library/Application Support/AgentHub"
        )
    }

    func testClaudeHookHelperInstallsBesideTheDaemon() {
        let paths = DaemonInstallation.paths(
            home: URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        )

        XCTAssertEqual(
            paths.claudeHookExecutable.path,
            "/Users/tester/Library/Application Support/AgentHub/bin/agenthub-claude-hook"
        )
    }

    func testPlistNeverCarriesTheHookHelperAsAnArgument() {
        let paths = DaemonInstallation.paths(
            home: URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        )
        let plist = DaemonInstallation.renderPlist(
            executable: paths.executable.path,
            pathEnvironment: "/usr/bin:/bin"
        )

        let arguments = plist["ProgramArguments"] as? [String] ?? []
        XCTAssertEqual(arguments, [paths.executable.path])
        XCTAssertFalse(arguments.contains { $0.contains("agenthub-claude-hook") })
    }

    func testInstallStagesBothHelpersAsExecutable() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let bundled = home.appendingPathComponent("Bundled", isDirectory: true)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        let daemon = try makeFakeExecutable(at: bundled.appendingPathComponent("agenthubd"))
        let hook = try makeFakeExecutable(
            at: bundled.appendingPathComponent("agenthub-claude-hook")
        )

        try DaemonInstallation.stageHelpers(
            daemon: daemon,
            claudeHook: hook,
            home: home
        )

        let paths = DaemonInstallation.paths(home: home)
        for helper in [paths.executable, paths.claudeHookExecutable] {
            XCTAssertTrue(
                FileManager.default.isExecutableFile(atPath: helper.path),
                "expected \(helper.lastPathComponent) to be executable"
            )
            let attributes = try FileManager.default.attributesOfItem(atPath: helper.path)
            XCTAssertEqual((attributes[.posixPermissions] as? Int).map { $0 & 0o777 }, 0o700)
        }
    }

    func testInstallRequiresTheClaudeHookHelper() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let bundled = home.appendingPathComponent("Bundled", isDirectory: true)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        let daemon = try makeFakeExecutable(at: bundled.appendingPathComponent("agenthubd"))
        let missing = bundled.appendingPathComponent("agenthub-claude-hook")

        XCTAssertThrowsError(
            try DaemonInstallation.stageHelpers(
                daemon: daemon,
                claudeHook: missing,
                home: home
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: DaemonInstallation.paths(home: home).executable.path
            ),
            "a missing hook helper must not leave a partially staged installation"
        )
    }

    private func temporaryHome() throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agenthub-install-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func makeFakeExecutable(at url: URL) throws -> URL {
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        return url
    }
}
