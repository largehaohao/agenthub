import XCTest
@testable import AgentHubApp

@MainActor
final class HoverControllerTests: XCTestCase {
    /// Fires scheduled work by hand so the delay is deterministic.
    @MainActor
    private final class ManualScheduler {
        private var pending: [() -> Void] = []

        func schedule(
            _ delay: TimeInterval,
            _ work: @escaping () -> Void
        ) -> HoverCancellable {
            pending.append(work)
            let index = pending.count - 1
            return Token { [weak self] in self?.pending[index] = {} }
        }

        func fireAll() {
            let work = pending
            pending = []
            work.forEach { $0() }
        }

        private final class Token: HoverCancellable {
            private let onCancel: () -> Void
            init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
            func cancel() { onCancel() }
        }
    }

    func testHoverShowsOnlyAfterTheDelay() {
        let scheduler = ManualScheduler()
        let controller = HoverController(delay: 0.3, schedule: { scheduler.schedule($0, $1) })

        controller.mouseEntered()
        XCTAssertFalse(controller.isVisible, "must not appear before the delay")

        scheduler.fireAll()
        XCTAssertTrue(controller.isVisible)
    }

    func testLeavingBeforeTheDelayNeverShows() {
        let scheduler = ManualScheduler()
        let controller = HoverController(delay: 0.3, schedule: { scheduler.schedule($0, $1) })

        controller.mouseEntered()
        controller.mouseExited()
        scheduler.fireAll()

        XCTAssertFalse(controller.isVisible, "sweeping past the icon must not open it")
    }

    func testLeavingHidesAnUnpinnedPanel() {
        let scheduler = ManualScheduler()
        let controller = HoverController(delay: 0.3, schedule: { scheduler.schedule($0, $1) })
        controller.mouseEntered()
        scheduler.fireAll()

        controller.mouseExited()

        XCTAssertFalse(controller.isVisible)
    }

    func testPinnedPanelSurvivesMouseExit() {
        let scheduler = ManualScheduler()
        let controller = HoverController(delay: 0.3, schedule: { scheduler.schedule($0, $1) })
        controller.mouseEntered()
        scheduler.fireAll()
        controller.pin()

        controller.mouseExited()

        XCTAssertTrue(controller.isVisible)
        XCTAssertTrue(controller.isPinned)
    }

    func testUnpinHidesImmediately() {
        let scheduler = ManualScheduler()
        let controller = HoverController(delay: 0.3, schedule: { scheduler.schedule($0, $1) })
        controller.mouseEntered()
        scheduler.fireAll()
        controller.pin()

        controller.unpin()

        XCTAssertFalse(controller.isVisible)
        XCTAssertFalse(controller.isPinned)
    }

    /// The shortcut opens the panel pinned without any pointer involvement.
    func testPinningDirectlyShowsThePanel() {
        let scheduler = ManualScheduler()
        let controller = HoverController(delay: 0.3, schedule: { scheduler.schedule($0, $1) })

        controller.pin()

        XCTAssertTrue(controller.isVisible)
    }

    /// The shortcut is a toggle: the same keys that opened the panel close it.
    func testTogglingPinsThenUnpins() {
        let scheduler = ManualScheduler()
        let controller = HoverController(delay: 0.3, schedule: { scheduler.schedule($0, $1) })

        controller.togglePinned()
        XCTAssertTrue(controller.isVisible)
        XCTAssertTrue(controller.isPinned)

        controller.togglePinned()
        XCTAssertFalse(controller.isVisible)
        XCTAssertFalse(controller.isPinned)
    }

    /// A panel already open from hover is pinned rather than dismissed: the
    /// shortcut's job is to make it stay, and closing what the pointer just
    /// opened would read as the shortcut doing nothing.
    func testTogglingAHoveredPanelPinsIt() {
        let scheduler = ManualScheduler()
        let controller = HoverController(delay: 0.3, schedule: { scheduler.schedule($0, $1) })
        controller.mouseEntered()
        scheduler.fireAll()

        controller.togglePinned()

        XCTAssertTrue(controller.isPinned)
        XCTAssertTrue(controller.isVisible)
    }

    /// Toggling closed while the pointer sits on the icon must not leave a
    /// pending show that reopens the panel a moment later.
    func testTogglingClosedDiscardsAPendingHover() {
        let scheduler = ManualScheduler()
        let controller = HoverController(delay: 0.3, schedule: { scheduler.schedule($0, $1) })
        controller.togglePinned()

        controller.mouseEntered()
        controller.togglePinned()
        scheduler.fireAll()

        XCTAssertFalse(controller.isVisible)
    }

    func testVisibilityChangesAreReportedOnce() {
        let scheduler = ManualScheduler()
        let controller = HoverController(delay: 0.3, schedule: { scheduler.schedule($0, $1) })
        var changes: [Bool] = []
        controller.onVisibilityChange = { changes.append($0) }

        controller.mouseEntered()
        scheduler.fireAll()
        controller.mouseEntered()
        controller.mouseExited()

        XCTAssertEqual(changes, [true, false])
    }
}
