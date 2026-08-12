import Foundation
import XCTest
import AgentHubCore
@testable import AgentHubClaude

final class ClaudeProcessClassifierTests: XCTestCase {
    private let classifier = ClaudeProcessClassifier()

    func testDesktopIsClassifiedFromClaudeApplicationAncestry() {
        let surface = classifier.surface(
            for: [
                observation(pid: 41, command: "claude"),
                observation(
                    pid: 40,
                    command: "/Applications/Claude.app/Contents/MacOS/Claude"
                ),
            ],
            managedSessionIDs: []
        )

        XCTAssertEqual(surface, .desktop)
    }

    func testManagedCLIRequiresARegisteredSessionAndTmuxAncestry() {
        let claudeID = UUID()
        let ancestors = [
            observation(pid: 41, command: "claude"),
            observation(pid: 40, command: "tmux"),
        ]

        XCTAssertEqual(
            classifier.surface(for: ancestors, managedSessionIDs: [claudeID], claudeSessionID: claudeID),
            .managedCLI
        )
        // The same ancestry without a registered UUID is only an external CLI;
        // AgentHub must never claim control of a session it did not launch.
        XCTAssertEqual(
            classifier.surface(for: ancestors, managedSessionIDs: [], claudeSessionID: claudeID),
            .externalCLI
        )
    }

    func testUnknownAncestryFallsBackToExternalCLI() {
        let surface = classifier.surface(
            for: [observation(pid: 41, command: "claude")],
            managedSessionIDs: []
        )

        XCTAssertEqual(surface, .externalCLI)
    }

    func testEmptyAncestryIsExternalCLIRatherThanDesktop() {
        XCTAssertEqual(classifier.surface(for: [], managedSessionIDs: []), .externalCLI)
    }

    func testSimilarlyNamedApplicationIsNotTreatedAsDesktop() {
        let surface = classifier.surface(
            for: [
                observation(pid: 41, command: "claude"),
                observation(pid: 40, command: "/Applications/ClaudeHelper.app/Contents/MacOS/Other"),
            ],
            managedSessionIDs: []
        )

        XCTAssertEqual(surface, .externalCLI)
    }

    private func observation(pid: Int32, command: String) -> ProcessObservation {
        ProcessObservation(
            pid: pid,
            parentPID: pid - 1,
            uid: 501,
            tty: "ttys001",
            command: command
        )
    }
}
