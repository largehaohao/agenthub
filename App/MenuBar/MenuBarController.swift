import AppKit
import SwiftUI

/// Owns the status item and the panel it shows.
///
/// The panel is a non-activating `NSPanel`, so showing it never takes focus
/// from whatever the user is actually working in.
@MainActor
final class MenuBarController: NSObject {
    private let model: QuotaPanelModel
    private let onOpenSettings: () -> Void
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private lazy var hover = HoverController(schedule: Self.schedule)

    init(model: QuotaPanelModel, onOpenSettings: @escaping () -> Void) {
        self.model = model
        self.onOpenSettings = onOpenSettings
        super.init()
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "gauge.with.dots.needle.33percent",
            accessibilityDescription: "AgentHub usage"
        )
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        statusItem = item

        if let button = item.button {
            button.addTrackingArea(
                NSTrackingArea(
                    rect: button.bounds,
                    options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                    owner: self,
                    userInfo: nil
                )
            )
        }

        hover.onVisibilityChange = { [weak self] visible in
            visible ? self?.showPanel() : self?.hidePanel()
        }
    }

    /// Shows the panel pinned, for the global shortcut.
    func revealPinned() {
        hover.pin()
    }

    // NSTrackingArea calls these on its owner; NSObject declares neither, so
    // they are @objc rather than overrides.
    @objc func mouseEntered(with event: NSEvent) {
        hover.mouseEntered()
        // Refresh opportunistically so the panel does not open showing a number
        // the user already knows is old. The service's own interval decides
        // whether this actually calls anything.
        Task { await model.load(force: false) }
    }

    @objc func mouseExited(with event: NSEvent) {
        hover.mouseExited()
    }

    @objc private func statusItemClicked() {
        hover.isPinned ? hover.unpin() : hover.pin()
    }

    private func showPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        if let button = statusItem?.button, let buttonWindow = button.window {
            let buttonFrame = buttonWindow.convertToScreen(button.frame)
            let x = buttonFrame.midX - panel.frame.width / 2
            let y = buttonFrame.minY - 8
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: y))
        }
        panel.orderFrontRegardless()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let view = QuotaPanelView(model: model, onOpenSettings: onOpenSettings)
        let hosting = NSHostingController(rootView: view)
        let panel = NSPanel(contentViewController: hosting)
        panel.styleMask = [.nonactivatingPanel, .fullSizeContentView, .titled]
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        return panel
    }

    private static func schedule(
        _ delay: TimeInterval,
        _ work: @escaping () -> Void
    ) -> HoverCancellable {
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return WorkItemToken(item)
    }

    private final class WorkItemToken: HoverCancellable {
        private let item: DispatchWorkItem
        init(_ item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }
}
