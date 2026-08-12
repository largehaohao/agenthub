import Foundation
import XCTest
import AgentHubCore
@testable import AgentHubClaude

final class ClaudeHookInstallerTests: XCTestCase {
    private var directory: URL!
    private var settingsURL: URL!
    private let executableURL = URL(fileURLWithPath: "/tmp/agenthub/bin/agenthub-claude-hook")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agenthub-hook-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        settingsURL = directory.appendingPathComponent("settings.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Install

    func testInstallPreservesExistingHooksAndIsIdempotent() throws {
        try writeSettings([
            "theme": "dark",
            "hooks": [
                "Stop": [
                    [
                        "hooks": [
                            ["type": "command", "command": "/usr/local/bin/existing-hook"],
                        ],
                    ],
                ],
            ],
        ])
        let installer = makeInstaller()

        try installer.install()
        try installer.install()

        let settings = try readSettings()
        XCTAssertEqual(settings["theme"] as? String, "dark")
        XCTAssertEqual(agentHubCommands(in: settings, event: "SessionStart").count, 1)
        // `Stop` is also an AgentHub-observed event, so the user's hook must
        // survive alongside exactly one AgentHub entry.
        XCTAssertEqual(agentHubCommands(in: settings, event: "Stop").count, 1)
        XCTAssertEqual(
            thirdPartyCommands(in: settings, event: "Stop"),
            ["/usr/local/bin/existing-hook"]
        )
    }

    func testInstallRegistersEveryDesignatedEventWithAbsoluteCommand() throws {
        try installer().install()

        let settings = try readSettings()
        for event in ClaudeHookInstaller.observedEvents {
            let commands = agentHubCommands(in: settings, event: event)
            XCTAssertEqual(commands.count, 1, "expected exactly one hook for \(event)")
            XCTAssertEqual(commands.first, executableURL.path)
        }
    }

    func testObserverHooksAreAsynchronousAndTimeBounded() throws {
        try installer().install()

        let settings = try readSettings()
        for event in ClaudeHookInstaller.observedEvents {
            let entries = agentHubEntries(in: settings, event: event)
            let entry = try XCTUnwrap(entries.first)
            XCTAssertEqual(entry["type"] as? String, "command")
            XCTAssertEqual(entry["async"] as? Bool, true)
            let timeout = try XCTUnwrap(entry["timeout"] as? Int)
            XCTAssertGreaterThan(timeout, 0)
            XCTAssertLessThanOrEqual(timeout, 10)
        }
    }

    func testInstallCreatesMissingSettingsFileWithOwnerOnlyMode() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path))

        try installer().install()

        XCTAssertEqual(try mode(of: settingsURL), 0o600)
        XCTAssertFalse(agentHubCommands(in: try readSettings(), event: "SessionStart").isEmpty)
    }

    func testInstallReplacingExistingSettingsKeepsOwnerOnlyMode() throws {
        try writeSettings(["theme": "dark"])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: settingsURL.path
        )

        try installer().install()

        XCTAssertEqual(try mode(of: settingsURL), 0o600)
    }

    func testMalformedSettingsLeavesOriginalBytesUnchanged() throws {
        let original = Data("{ this is not valid json".utf8)
        try original.write(to: settingsURL)

        XCTAssertThrowsError(try installer().install()) { error in
            XCTAssertEqual(error as? ClaudeHookInstallerError, .malformedSettings)
        }
        XCTAssertEqual(try Data(contentsOf: settingsURL), original)
    }

    func testSettingsWithNonObjectRootIsRejected() throws {
        try Data("[1, 2, 3]".utf8).write(to: settingsURL)

        XCTAssertThrowsError(try installer().install()) { error in
            XCTAssertEqual(error as? ClaudeHookInstallerError, .malformedSettings)
        }
    }

    // MARK: - Uninstall

    func testUninstallRemovesOnlyExactAgentHubExecutable() throws {
        try writeSettings([
            "hooks": [
                "Stop": [
                    [
                        "hooks": [
                            ["type": "command", "command": "/usr/local/bin/existing-hook"],
                        ],
                    ],
                ],
            ],
        ])
        let installer = makeInstaller()
        try installer.install()

        try installer.uninstall()

        let settings = try readSettings()
        XCTAssertTrue(agentHubCommands(in: settings, event: "SessionStart").isEmpty)
        XCTAssertEqual(
            allCommands(in: settings, event: "Stop"),
            ["/usr/local/bin/existing-hook"]
        )
    }

    func testUninstallKeepsSimilarlyNamedThirdPartyCommands() throws {
        let lookalikes = [
            "/opt/other/agenthub-claude-hook",
            "/tmp/agenthub/bin/agenthub-claude-hook-extra",
            "/tmp/agenthub/bin/agenthub-claude-hook --flag",
        ]
        try writeSettings([
            "hooks": [
                "SessionStart": [
                    ["hooks": lookalikes.map { ["type": "command", "command": $0] }],
                ],
            ],
        ])
        let installer = makeInstaller()
        try installer.install()

        try installer.uninstall()

        let remaining = allCommands(in: try readSettings(), event: "SessionStart")
        XCTAssertEqual(remaining.sorted(), lookalikes.sorted())
    }

    func testUninstallNormalizesEquivalentPathSpellings() throws {
        try writeSettings([
            "hooks": [
                "SessionStart": [
                    [
                        "hooks": [
                            [
                                "type": "command",
                                "command": "/tmp/agenthub/./bin/../bin/agenthub-claude-hook",
                            ],
                        ],
                    ],
                ],
            ],
        ])

        try makeInstaller().uninstall()

        XCTAssertTrue(allCommands(in: try readSettings(), event: "SessionStart").isEmpty)
    }

    func testUninstallOnMissingSettingsFileSucceedsWithoutCreatingOne() throws {
        try makeInstaller().uninstall()

        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path))
    }

    // MARK: - Status

    func testStatusReportsInstalledStateAndPath() throws {
        let installer = makeInstaller()

        let before = try installer.status()
        XCTAssertEqual(before.provider, .claude)
        XCTAssertEqual(before.component, "hooks")
        XCTAssertFalse(before.available)

        try installer.install()

        let after = try installer.status()
        XCTAssertTrue(after.available)
        XCTAssertEqual(after.path, executableURL.path)
    }

    func testStatusReportsPartialInstallationAsUnavailable() throws {
        let installer = makeInstaller()
        try installer.install()

        var settings = try readSettings()
        var hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        hooks.removeValue(forKey: "Stop")
        settings["hooks"] = hooks
        try writeSettings(settings)

        XCTAssertFalse(try installer.status().available)
    }

    func testStatusOnMalformedSettingsReportsUnavailableWithoutThrowing() throws {
        try Data("{ broken".utf8).write(to: settingsURL)

        let status = try makeInstaller().status()
        XCTAssertFalse(status.available)
    }

    // MARK: - Helpers

    private func installer() -> ClaudeHookInstaller { makeInstaller() }

    private func makeInstaller() -> ClaudeHookInstaller {
        ClaudeHookInstaller(
            settingsURL: settingsURL,
            executableURL: executableURL,
            now: { Date(timeIntervalSince1970: 1) }
        )
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: settings)
        try data.write(to: settingsURL)
    }

    private func readSettings() throws -> [String: Any] {
        let data = try Data(contentsOf: settingsURL)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? Int) & 0o777
    }

    private func agentHubEntries(
        in settings: [String: Any],
        event: String
    ) -> [[String: Any]] {
        entries(in: settings, event: event).filter {
            ($0["command"] as? String) == executableURL.path
        }
    }

    private func agentHubCommands(in settings: [String: Any], event: String) -> [String] {
        agentHubEntries(in: settings, event: event).compactMap { $0["command"] as? String }
    }

    private func thirdPartyCommands(in settings: [String: Any], event: String) -> [String] {
        allCommands(in: settings, event: event).filter { $0 != executableURL.path }
    }

    private func allCommands(in settings: [String: Any], event: String) -> [String] {
        entries(in: settings, event: event).compactMap { $0["command"] as? String }
    }

    private func entries(in settings: [String: Any], event: String) -> [[String: Any]] {
        guard let hooks = settings["hooks"] as? [String: Any],
              let matchers = hooks[event] as? [[String: Any]] else { return [] }
        return matchers.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
    }
}
