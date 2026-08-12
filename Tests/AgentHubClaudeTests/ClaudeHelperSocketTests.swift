import Foundation
import XCTest
@testable import AgentHubClaude

/// The helper executables resolve their socket from Application Support, which
/// macOS derives from the user record rather than `HOME`. Without an override
/// there is no way to exercise real socket delivery except by writing to the
/// user's live daemon, so these pin the override that makes it testable.
final class ClaudeHelperSocketTests: XCTestCase {
    func testDefaultsToApplicationSupportWhenNoOverrideIsSet() throws {
        let path = try ClaudeHelperSocket.resolve(environment: [:])

        XCTAssertTrue(path.hasSuffix("/AgentHub/agenthub.sock"))
        XCTAssertTrue(path.contains("Application Support"))
    }

    func testOverrideIsUsedWhenPresent() throws {
        let path = try ClaudeHelperSocket.resolve(
            environment: ["AGENTHUB_SOCKET": "/tmp/test/agenthub.sock"]
        )

        XCTAssertEqual(path, "/tmp/test/agenthub.sock")
    }

    func testEmptyOverrideFallsBackRatherThanUsingAnEmptyPath() throws {
        let path = try ClaudeHelperSocket.resolve(environment: ["AGENTHUB_SOCKET": ""])

        XCTAssertTrue(path.hasSuffix("/AgentHub/agenthub.sock"))
    }
}
