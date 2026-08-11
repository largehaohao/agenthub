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
}
