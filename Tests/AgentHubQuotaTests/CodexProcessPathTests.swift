import XCTest
@testable import AgentHubQuota

/// The environment an app launched from Finder or Spotlight actually gets:
/// launchd's PATH, which holds none of the places a per-user CLI installs to.
private let guiLaunch = [
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "HOME": "/Users/example",
]

final class CodexProcessPathTests: XCTestCase {
    func testSearchPathCoversPerUserToolDirectories() {
        let path = CodexProcess.searchPath(guiLaunch)

        XCTAssertTrue(
            path.contains("/Users/example/.local/bin"),
            "a GUI launch must still find a CLI installed under the home directory"
        )
        XCTAssertTrue(path.contains("/opt/homebrew/bin"))
        XCTAssertTrue(path.contains("/usr/local/bin"))
    }

    /// A user who has put a particular codex on their PATH means that one.
    func testInheritedEntriesKeepPriority() {
        let path = CodexProcess.searchPath([
            "PATH": "/custom/bin:/usr/bin",
            "HOME": "/Users/example",
        ])

        XCTAssertEqual(path.first, "/custom/bin")
        XCTAssertLessThan(
            try XCTUnwrap(path.firstIndex(of: "/usr/bin")),
            try XCTUnwrap(path.firstIndex(of: "/opt/homebrew/bin"))
        )
    }

    /// A directory on both lists must not be searched twice.
    func testDirectoriesAreNotDuplicated() {
        let path = CodexProcess.searchPath([
            "PATH": "/opt/homebrew/bin:/usr/local/bin",
            "HOME": "/Users/example",
        ])

        XCTAssertEqual(path.count, Set(path).count)
    }

    /// The search path doubles as the child's PATH, because codex is a Node
    /// script whose `/usr/bin/env node` shebang has to resolve as well.
    func testSearchPathCanSatisfyTheShebang() {
        let path = CodexProcess.searchPath(guiLaunch)

        XCTAssertTrue(
            path.contains("/opt/homebrew/bin") && path.contains("/Users/example/.local/bin"),
            "node lives in the same per-user or Homebrew directories as codex"
        )
    }

    /// An environment with no HOME still has to produce a usable list.
    func testMissingHomeFallsBackToTheCurrentUser() {
        let path = CodexProcess.searchPath(["PATH": "/usr/bin"])

        XCTAssertFalse(path.isEmpty)
        XCTAssertTrue(path.contains { $0.hasSuffix("/.local/bin") })
    }
}
