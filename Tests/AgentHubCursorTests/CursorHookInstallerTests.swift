import Foundation
import XCTest
@testable import AgentHubCursor

final class CursorHookInstallerTests: XCTestCase {
    func testInstallMergesBesideExistingOpenIslandHooks() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let hooksURL = dir.appendingPathComponent("hooks.json")
        let existing = """
        {"version":1,"hooks":{"beforeSubmitPrompt":[{"command":"/tmp/OpenIslandHooks --source cursor"}],"stop":[{"command":"/tmp/OpenIslandHooks --source cursor"}]}}
        """
        try Data(existing.utf8).write(to: hooksURL)
        let helper = dir.appendingPathComponent("agenthub-cursor-hook")
        try Data().write(to: helper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helper.path
        )

        let installer = CursorHookInstaller(hooksURL: hooksURL, executableURL: helper)
        try installer.install()

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as! [String: Any]
        let hooks = json["hooks"] as! [String: Any]
        let prompt = hooks["beforeSubmitPrompt"] as! [[String: Any]]
        XCTAssertEqual(prompt.count, 2)
        XCTAssertTrue(prompt.contains { ($0["command"] as? String) == helper.path })
        XCTAssertTrue(
            prompt.contains { ($0["command"] as? String)?.contains("OpenIsland") == true }
        )

        let shell = hooks["beforeShellExecution"] as! [[String: Any]]
        XCTAssertEqual(shell.count, 1)
        XCTAssertEqual(shell[0]["failClosed"] as? Bool, true)
        XCTAssertEqual(shell[0]["command"] as? String, helper.path)
    }

    func testUninstallRemovesOnlyAgentHubCommands() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let hooksURL = dir.appendingPathComponent("hooks.json")
        let helper = dir.appendingPathComponent("agenthub-cursor-hook")
        try Data().write(to: helper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helper.path
        )

        let existing = """
        {"version":1,"hooks":{"stop":[{"command":"/tmp/OpenIslandHooks --source cursor"},{"command":"\(helper.path)"}]}}
        """
        try Data(existing.utf8).write(to: hooksURL)

        let installer = CursorHookInstaller(hooksURL: hooksURL, executableURL: helper)
        try installer.uninstall()

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as! [String: Any]
        let hooks = json["hooks"] as! [String: Any]
        let stop = hooks["stop"] as! [[String: Any]]
        XCTAssertEqual(stop.count, 1)
        XCTAssertTrue((stop[0]["command"] as? String)?.contains("OpenIsland") == true)
    }

    func testReinstallDoesNotDuplicateAgentHubEntries() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let hooksURL = dir.appendingPathComponent("hooks.json")
        let helper = dir.appendingPathComponent("agenthub-cursor-hook")
        try Data().write(to: helper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helper.path
        )

        let installer = CursorHookInstaller(hooksURL: hooksURL, executableURL: helper)
        try installer.install()
        try installer.install()

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as! [String: Any]
        let hooks = json["hooks"] as! [String: Any]
        for event in CursorHookInstaller.observedEvents {
            let entries = hooks[event] as! [[String: Any]]
            let owned = entries.filter { ($0["command"] as? String) == helper.path }
            XCTAssertEqual(owned.count, 1, event)
        }

        let status = try installer.status()
        XCTAssertTrue(status.available)
        XCTAssertEqual(status.path, helper.path)
    }
}
