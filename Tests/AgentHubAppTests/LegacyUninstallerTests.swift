import XCTest
@testable import AgentHubApp

/// Removing entries the user did not add is the whole risk here, so these tests
/// are mostly about what must survive.
final class LegacyUninstallerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agenthub-uninstall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func uninstaller(
        claude: String = "absent-claude.json",
        cursor: String = "absent-cursor.json",
        launchAgent: String = "absent.plist"
    ) -> LegacyUninstaller {
        LegacyUninstaller(
            claudeSettingsURL: directory.appendingPathComponent(claude),
            cursorHooksURL: directory.appendingPathComponent(cursor),
            launchAgentURL: directory.appendingPathComponent(launchAgent)
        )
    }

    private func readObject(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testRemovesAgentHubClaudeHooksAndKeepsForeignOnes() throws {
        try Data("""
        {"statusLine":{"command":"payload=$(cat); '/x/AgentHub/bin/agenthub-claude-statusline'; sh ~/.claude/mine.sh"},
         "theme":"dark",
         "hooks":{"SessionStart":[
           {"hooks":[{"type":"command","command":"'/x/AgentHub/bin/agenthub-claude-hook'"}]},
           {"hooks":[{"type":"command","command":"'/Users/me/.local/bin/jcode' setup"}]}]}}
        """.utf8).write(to: directory.appendingPathComponent("settings.json"))

        let summary = try uninstaller(claude: "settings.json").run()

        let root = try readObject("settings.json")
        let commands = ((root["hooks"] as! [String: Any])["SessionStart"] as! [[String: Any]])
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }

        XCTAssertEqual(summary.removedClaudeHooks, 1)
        XCTAssertTrue(commands.allSatisfy { !$0.contains("agenthub") })
        XCTAssertEqual(commands.filter { $0.contains("jcode") }.count, 1)
        XCTAssertEqual(root["theme"] as? String, "dark", "unrelated settings survive")
        XCTAssertNil(root["statusLine"], "AgentHub's status line wrapper is removed")
    }

    /// A status line the user wrote themselves is not ours to delete.
    func testForeignStatusLineIsLeftAlone() throws {
        try Data("""
        {"statusLine":{"command":"sh ~/.claude/mine.sh"}}
        """.utf8).write(to: directory.appendingPathComponent("settings.json"))

        _ = try uninstaller(claude: "settings.json").run()

        let root = try readObject("settings.json")
        XCTAssertNotNil(root["statusLine"])
    }

    func testRemovesAgentHubCursorHooksAndKeepsPeers() throws {
        try Data("""
        {"version":1,"hooks":{"beforeShellExecution":[
          {"command":"'/x/AgentHub/bin/agenthub-cursor-hook'"},
          {"command":"'/Users/me/.openisland/hook'"}]}}
        """.utf8).write(to: directory.appendingPathComponent("hooks.json"))

        let summary = try uninstaller(cursor: "hooks.json").run()

        let root = try readObject("hooks.json")
        let commands = ((root["hooks"] as! [String: Any])["beforeShellExecution"] as! [[String: Any]])
            .compactMap { $0["command"] as? String }

        XCTAssertEqual(summary.removedCursorHooks, 1)
        XCTAssertEqual(commands, ["'/Users/me/.openisland/hook'"])
    }

    func testMissingFilesAreNotAnError() throws {
        let summary = try uninstaller().run()

        XCTAssertEqual(summary.removedClaudeHooks, 0)
        XCTAssertEqual(summary.removedCursorHooks, 0)
        XCTAssertFalse(summary.removedLaunchAgent)
    }

    func testABackupIsWrittenBeforeEditing() throws {
        try Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"'/x/AgentHub/bin/agenthub-claude-hook'"}]}]}}"#.utf8)
            .write(to: directory.appendingPathComponent("settings.json"))

        _ = try uninstaller(claude: "settings.json").run()

        let backups = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains("agenthub-backup") }
        XCTAssertEqual(backups.count, 1)
    }

    /// An event left with no entries should not linger as an empty array.
    func testEmptiedEventsAreRemoved() throws {
        try Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"'/x/AgentHub/bin/agenthub-claude-hook'"}]}]}}"#.utf8)
            .write(to: directory.appendingPathComponent("settings.json"))

        _ = try uninstaller(claude: "settings.json").run()

        let root = try readObject("settings.json")
        XCTAssertNil(root["hooks"], "no events left means no hooks key")
    }
}
