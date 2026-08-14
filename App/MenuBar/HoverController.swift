import Foundation

/// Cancels work scheduled by `HoverController`.
///
/// Named to avoid colliding with Combine's `Cancellable`, which SwiftUI brings
/// into scope.
protocol HoverCancellable: AnyObject {
    func cancel()
}

/// Decides when the usage panel is on screen.
///
/// Hover opens the panel only after a short delay, so moving the pointer across
/// the menu bar to reach another item does not flash it open. Pinning survives
/// mouse exit; unpinning closes at once.
@MainActor
final class HoverController {
    private let delay: TimeInterval
    private let schedule: @MainActor (TimeInterval, @escaping () -> Void) -> HoverCancellable

    private var pendingShow: HoverCancellable?

    private(set) var isVisible = false {
        didSet {
            guard isVisible != oldValue else { return }
            onVisibilityChange?(isVisible)
        }
    }
    private(set) var isPinned = false

    var onVisibilityChange: ((Bool) -> Void)?

    init(
        delay: TimeInterval = 0.3,
        schedule: @escaping @MainActor (TimeInterval, @escaping () -> Void) -> HoverCancellable
    ) {
        self.delay = delay
        self.schedule = schedule
    }

    func mouseEntered() {
        guard !isVisible, pendingShow == nil else { return }
        pendingShow = schedule(delay) { [weak self] in
            guard let self else { return }
            self.pendingShow = nil
            self.isVisible = true
        }
    }

    func mouseExited() {
        pendingShow?.cancel()
        pendingShow = nil
        guard !isPinned else { return }
        isVisible = false
    }

    func pin() {
        pendingShow?.cancel()
        pendingShow = nil
        isPinned = true
        isVisible = true
    }

    func unpin() {
        isPinned = false
        isVisible = false
    }
}
