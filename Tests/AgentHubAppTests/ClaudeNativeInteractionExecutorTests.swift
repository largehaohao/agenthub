import Foundation
import XCTest
import AgentHubCore
@testable import AgentHubApp

final class ClaudeNativeInteractionExecutorTests: XCTestCase {
    private let plan = NativeInteractionPlan(
        id: UUID(),
        provider: .claude,
        requestID: UUID(),
        bundleID: "com.anthropic.claudefordesktop",
        windowHint: "agenthub",
        sessionNativeID: "abc123",
        promptFingerprint: "fingerprint",
        operation: .choose(label: "Yes")
    )

    func testExecutesOnlyWhenEverythingMatchesExactly() async throws {
        let surface = FakeAccessibilitySurface(windows: [matchingWindow])
        let executor = makeExecutor(surface: surface, trusted: true)

        try await executor.execute(plan)

        let actions = await surface.performedActions()
        XCTAssertEqual(actions, [.choose("Yes")])
    }

    func testMissingAccessibilityPermissionPerformsNoUIAction() async {
        let surface = FakeAccessibilitySurface(windows: [matchingWindow])
        let executor = makeExecutor(surface: surface, trusted: false)

        await assertRefuses(executor, plan, expecting: .accessibilityUnavailable)

        let actions = await surface.performedActions()
        XCTAssertTrue(actions.isEmpty)
        // The app still brings Claude forward so the user can act natively.
        let activated = await surface.activatedBundleIDs()
        XCTAssertEqual(activated, ["com.anthropic.claudefordesktop"])
    }

    func testAmbiguousWindowsPerformNoUIAction() async {
        let surface = FakeAccessibilitySurface(windows: [matchingWindow, matchingWindow])
        let executor = makeExecutor(surface: surface, trusted: true)

        await assertRefuses(executor, plan, expecting: .ambiguousTarget)

        let actions = await surface.performedActions()
        XCTAssertTrue(actions.isEmpty)
    }

    func testWrongSessionTitlePerformsNoUIAction() async {
        var window = matchingWindow
        window.sessionNativeID = "different-session"
        let executor = makeExecutor(
            surface: FakeAccessibilitySurface(windows: [window]),
            trusted: true
        )

        await assertRefuses(executor, plan, expecting: .noMatchingTarget)
    }

    func testWrongPromptFingerprintPerformsNoUIAction() async {
        var window = matchingWindow
        window.promptFingerprint = "the-screen-moved-on"
        let surface = FakeAccessibilitySurface(windows: [window])
        let executor = makeExecutor(surface: surface, trusted: true)

        await assertRefuses(executor, plan, expecting: .stalePrompt)

        let actions = await surface.performedActions()
        XCTAssertTrue(actions.isEmpty)
    }

    func testOptionMissingFromTheVisibleUIPerformsNoUIAction() async {
        var window = matchingWindow
        window.options = ["Allow once", "Deny"]
        let surface = FakeAccessibilitySurface(windows: [window])
        let executor = makeExecutor(surface: surface, trusted: true)

        await assertRefuses(executor, plan, expecting: .noMatchingTarget)

        let actions = await surface.performedActions()
        XCTAssertTrue(actions.isEmpty)
    }

    func testNoRunningApplicationPerformsNoUIAction() async {
        let surface = FakeAccessibilitySurface(windows: [])
        let executor = makeExecutor(surface: surface, trusted: true)

        await assertRefuses(executor, plan, expecting: .noMatchingTarget)

        let actions = await surface.performedActions()
        XCTAssertTrue(actions.isEmpty)
    }

    func testTextEntryRequiresTheSameVerification() async throws {
        let surface = FakeAccessibilitySurface(windows: [matchingWindow])
        let executor = makeExecutor(surface: surface, trusted: true)
        let typing = NativeInteractionPlan(
            id: plan.id,
            provider: .claude,
            requestID: plan.requestID,
            bundleID: plan.bundleID,
            windowHint: plan.windowHint,
            sessionNativeID: plan.sessionNativeID,
            promptFingerprint: plan.promptFingerprint,
            operation: .enter(text: "looks good")
        )

        try await executor.execute(typing)

        let actions = await surface.performedActions()
        XCTAssertEqual(actions, [.enter("looks good")])
    }

    func testNonClaudePlanIsRefused() async {
        let surface = FakeAccessibilitySurface(windows: [matchingWindow])
        let executor = makeExecutor(surface: surface, trusted: true)
        let foreign = NativeInteractionPlan(
            id: plan.id,
            provider: .codex,
            requestID: plan.requestID,
            bundleID: plan.bundleID,
            windowHint: plan.windowHint,
            sessionNativeID: plan.sessionNativeID,
            promptFingerprint: plan.promptFingerprint,
            operation: plan.operation
        )

        await assertRefuses(executor, foreign, expecting: .noMatchingTarget)
    }

    // MARK: - Helpers

    private var matchingWindow: FakeAccessibilityWindow {
        FakeAccessibilityWindow(
            bundleID: "com.anthropic.claudefordesktop",
            sessionNativeID: "abc123",
            promptFingerprint: "fingerprint",
            options: ["Yes", "Yes, and don't ask again", "No"]
        )
    }

    private func makeExecutor(
        surface: FakeAccessibilitySurface,
        trusted: Bool
    ) -> ClaudeNativeInteractionExecutor {
        ClaudeNativeInteractionExecutor(surface: surface, isTrusted: { trusted })
    }

    private func assertRefuses(
        _ executor: ClaudeNativeInteractionExecutor,
        _ plan: NativeInteractionPlan,
        expecting expected: NativeInteractionError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await executor.execute(plan)
            XCTFail("expected the plan to be refused", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? NativeInteractionError, expected, file: file, line: line)
        }
    }
}

struct FakeAccessibilityWindow: Equatable {
    var bundleID: String
    var sessionNativeID: String
    var promptFingerprint: String
    var options: [String]
}

enum FakeUIAction: Equatable {
    case choose(String)
    case enter(String)
}

actor FakeAccessibilitySurface: ClaudeAccessibilitySurface {
    private let windows: [FakeAccessibilityWindow]
    private var actions: [FakeUIAction] = []
    private var activated: [String] = []

    init(windows: [FakeAccessibilityWindow]) {
        self.windows = windows
    }

    func performedActions() -> [FakeUIAction] { actions }
    func activatedBundleIDs() -> [String] { activated }

    func matchingWindows(bundleID: String, sessionNativeID: String) async -> [ClaudeWindowSnapshot] {
        windows
            .filter { $0.bundleID == bundleID && $0.sessionNativeID == sessionNativeID }
            .map {
                ClaudeWindowSnapshot(
                    sessionNativeID: $0.sessionNativeID,
                    promptFingerprint: $0.promptFingerprint,
                    visibleOptions: $0.options
                )
            }
    }

    func choose(label: String, in window: ClaudeWindowSnapshot) async throws {
        actions.append(.choose(label))
    }

    func enter(text: String, in window: ClaudeWindowSnapshot) async throws {
        actions.append(.enter(text))
    }

    func activate(bundleID: String) async {
        activated.append(bundleID)
    }
}
