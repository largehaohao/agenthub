import Foundation
import XCTest
@testable import AgentHubClaude

final class ClaudeStatusLineInstallerTests: XCTestCase {
    private var directory: URL!
    private var settingsURL: URL!
    private let reporter = URL(fileURLWithPath: "/tmp/agenthub/bin/agenthub-claude-statusline")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        settingsURL = directory.appendingPathComponent("settings.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Preserving the user's own status line

    func testInstallWrapsAnExistingUserStatusLineInsteadOfReplacingIt() throws {
        try writeSettings([
            "theme": "dark",
            "statusLine": ["type": "command", "command": "sh /Users/me/my-statusline.sh"],
        ])

        try makeInstaller().install()

        let settings = try readSettings()
        let line = try XCTUnwrap(settings["statusLine"] as? [String: Any])
        let command = try XCTUnwrap(line["command"] as? String)
        // AgentHub's reporter runs, and the user's own command still runs and
        // still owns what is displayed.
        XCTAssertTrue(command.contains(reporter.path))
        XCTAssertTrue(command.contains("sh /Users/me/my-statusline.sh"))
        XCTAssertEqual(settings["theme"] as? String, "dark")
    }

    func testInstallIsIdempotentAndDoesNotNestWrappers() throws {
        try writeSettings([
            "statusLine": ["type": "command", "command": "sh /Users/me/my-statusline.sh"],
        ])

        try makeInstaller().install()
        let afterFirst = try XCTUnwrap(
            (try readSettings()["statusLine"] as? [String: Any])?["command"] as? String
        )
        try makeInstaller().install()
        let afterSecond = try XCTUnwrap(
            (try readSettings()["statusLine"] as? [String: Any])?["command"] as? String
        )

        XCTAssertEqual(afterFirst, afterSecond)
        XCTAssertEqual(occurrences(of: reporter.path, in: afterSecond), 1)
        XCTAssertEqual(occurrences(of: "my-statusline.sh", in: afterSecond), 1)
    }

    func testInstallWithoutAnExistingStatusLineStillReports() throws {
        try writeSettings(["theme": "dark"])

        try makeInstaller().install()

        let command = try XCTUnwrap(
            (try readSettings()["statusLine"] as? [String: Any])?["command"] as? String
        )
        XCTAssertTrue(command.contains(reporter.path))
    }

    // MARK: - Uninstall

    func testUninstallRestoresTheUsersOriginalCommandExactly() throws {
        try writeSettings([
            "theme": "dark",
            "statusLine": ["type": "command", "command": "sh /Users/me/my-statusline.sh"],
        ])
        try makeInstaller().install()

        try makeInstaller().uninstall()

        let settings = try readSettings()
        let line = try XCTUnwrap(settings["statusLine"] as? [String: Any])
        XCTAssertEqual(line["command"] as? String, "sh /Users/me/my-statusline.sh")
        XCTAssertEqual(settings["theme"] as? String, "dark")
    }

    func testUninstallRemovesTheKeyWhenAgentHubIntroducedIt() throws {
        try writeSettings(["theme": "dark"])
        try makeInstaller().install()

        try makeInstaller().uninstall()

        let settings = try readSettings()
        XCTAssertNil(settings["statusLine"])
        XCTAssertEqual(settings["theme"] as? String, "dark")
    }

    func testUninstallLeavesAThirdPartyStatusLineUntouched() throws {
        try writeSettings([
            "statusLine": ["type": "command", "command": "sh /Users/me/other.sh"],
        ])

        try makeInstaller().uninstall()

        let command = try XCTUnwrap(
            (try readSettings()["statusLine"] as? [String: Any])?["command"] as? String
        )
        XCTAssertEqual(command, "sh /Users/me/other.sh")
    }

    // MARK: - Safety

    func testMalformedSettingsAreLeftByteIdentical() throws {
        let original = Data("{ not json".utf8)
        try original.write(to: settingsURL)

        XCTAssertThrowsError(try makeInstaller().install()) { error in
            XCTAssertEqual(
                error as? ClaudeHookInstallerError,
                .malformedSettings
            )
        }
        XCTAssertEqual(try Data(contentsOf: settingsURL), original)
    }

    func testWrittenSettingsAreUserOnlyReadable() throws {
        try writeSettings(["theme": "dark"])

        try makeInstaller().install()

        let mode = try FileManager.default
            .attributesOfItem(atPath: settingsURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value ?? 0 & 0o777, 0o600)
    }

    func testStatusIsUnavailableBeforeInstallAndAvailableAfter() throws {
        try writeSettings(["theme": "dark"])

        XCTAssertFalse(try makeInstaller().status().available)
        try makeInstaller().install()
        let status = try makeInstaller().status()
        XCTAssertTrue(status.available)
        XCTAssertEqual(status.component, "statusline")
        XCTAssertEqual(status.path, reporter.path)
    }

    // MARK: - Helpers

    private func makeInstaller() -> ClaudeStatusLineInstaller {
        ClaudeStatusLineInstaller(
            settingsURL: settingsURL,
            executableURL: reporter,
            now: { Date(timeIntervalSince1970: 1) }
        )
    }

    private func writeSettings(_ value: [String: Any]) throws {
        try JSONSerialization
            .data(withJSONObject: value, options: [.prettyPrinted])
            .write(to: settingsURL)
    }

    private func readSettings() throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: settingsURL))
                as? [String: Any]
        )
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
