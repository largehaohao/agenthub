import AppKit
import Combine
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
    /// Where the panel's top-left corner belongs. A window resizes from its
    /// bottom-left, so zooming the contents would otherwise walk the panel up
    /// under the menu bar.
    private var anchor: NSPoint?
    private var contentObserver: AnyCancellable?
    private var clickAwayMonitor: Any?
    private lazy var hover = HoverController(schedule: Self.schedule)

    init(model: QuotaPanelModel, onOpenSettings: @escaping () -> Void) {
        self.model = model
        self.onOpenSettings = onOpenSettings
        super.init()
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.menuBarImage()
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        // Right-click is where macOS users look for an app's own commands, and
        // it works whether or not the panel is open.
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
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
            guard let self else { return }
            visible ? self.showPanel() : self.hidePanel()
            self.watchForClickAway(visible)
        }
    }

    private static func menuBarImage() -> NSImage {
        if let image = NSImage(named: "MenuBarQ") {
            image.isTemplate = true
            image.accessibilityDescription = "AgentHub usage"
            return image
        }

        return NSImage(
            systemSymbolName: "gauge.with.dots.needle.33percent",
            accessibilityDescription: "AgentHub usage"
        )!
    }

    /// Opens the panel pinned, or closes it if the shortcut is pressed again.
    func togglePinned() {
        hover.togglePinned()
        guard hover.isPinned else { return }
        // The shortcut is the one way in that skips the tracking area, so
        // without this it shows whatever the last hover or the startup refresh
        // left behind. The service's own interval decides whether this calls
        // anything.
        Task { await model.load(force: false) }
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
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
            return
        }
        // Clicking the icon and pressing the shortcut are the same gesture, so
        // they behave identically — including the refresh.
        togglePinned()
    }

    private func showMenu() {
        hover.unpin()
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh Usage", action: #selector(refreshFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit AgentHub", action: #selector(quitFromMenu), keyEquivalent: "q")
        for item in menu.items where item.action != nil { item.target = self }

        // Attaching the menu makes the next click open it; detaching afterwards
        // restores the plain click-to-toggle behaviour.
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func refreshFromMenu() {
        Task { await model.load(force: true) }
    }

    @objc private func openSettingsFromMenu() {
        onOpenSettings()
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    private func showPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        reanchor(recentre: true)
        panel.orderFrontRegardless()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }

    /// Dismisses the panel when the user clicks anywhere else.
    ///
    /// A glance panel that stays up after you have moved on is clutter, and
    /// clicking away is what every other menu bar app does. Clicks inside our
    /// own windows are local events, so this only ever sees clicks elsewhere.
    private func watchForClickAway(_ watching: Bool) {
        guard watching != (clickAwayMonitor != nil) else { return }
        if watching {
            clickAwayMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                self?.hover.unpin()
            }
        } else if let clickAwayMonitor {
            NSEvent.removeMonitor(clickAwayMonitor)
            self.clickAwayMonitor = nil
        }
    }

    /// Grows or shrinks the panel to match its contents.
    ///
    /// Deliberately not left to `NSHostingController.sizingOptions`: letting it
    /// drive `preferredContentSize` made the window ask for a constraint update
    /// from inside one, and AppKit raised on the re-entry. Resizing on a later
    /// runloop pass keeps the two out of each other's way.
    ///
    /// Does not re-centre. The panel is open and under the pointer, and shifting
    /// it by half the width it just gained would move the zoom button out from
    /// under the click that caused the resize.
    private func resizeToFit() {
        guard let panel, let content = panel.contentViewController?.view else { return }
        let size = content.fittingSize
        guard size.width > 0, size.height > 0, size != panel.contentLayoutRect.size else {
            return
        }

        // Zooming past the screen would put the close button out of reach, so
        // the last step that no longer fits is given back.
        if let screen = panelScreen(), size.height > screen.visibleFrame.height - 16 {
            model.refuseEnlargement()
            return
        }

        panel.setContentSize(size)
        reanchor(recentre: false)
    }

    /// Hangs the panel's top-left corner just below the status item.
    ///
    /// - Parameter recentre: centre it on the status item. Done when the panel
    ///   is shown, not when it merely changes size.
    private func reanchor(recentre: Bool) {
        guard let panel else { return }
        guard let button = statusItem?.button, let window = button.window else {
            if let anchor { panel.setFrameTopLeftPoint(anchor) }
            return
        }
        let buttonFrame = window.convertToScreen(button.frame)
        var point = NSPoint(
            x: recentre ? buttonFrame.midX - panel.frame.width / 2 : (anchor?.x ?? buttonFrame.minX),
            y: buttonFrame.minY - 8
        )
        // A panel zoomed wide under a status item near the right edge would
        // otherwise hang off the screen.
        if let visible = panelScreen()?.visibleFrame {
            let rightmost = visible.maxX - panel.frame.width - 8
            point.x = min(max(point.x, visible.minX + 8), max(rightmost, visible.minX + 8))
        }
        anchor = point
        panel.setFrameTopLeftPoint(point)
    }

    /// The display the status item is on.
    ///
    /// Not `button.window?.screen`: with more than one display that reports the
    /// screen holding the active menu bar, which is not necessarily this one,
    /// and clamping against the wrong bounds let the panel run off the edge.
    private func panelScreen() -> NSScreen? {
        guard let button = statusItem?.button, let window = button.window else {
            return NSScreen.main
        }
        let buttonFrame = window.convertToScreen(button.frame)
        return NSScreen.screens.first { $0.frame.intersects(buttonFrame) }
            ?? window.screen
            ?? NSScreen.main
    }

    private func makePanel() -> NSPanel {
        let view = QuotaPanelView(
            model: model,
            // The panel floats at status-bar level, so it covers the settings
            // window it just opened. Standing aside is the whole intent of the
            // click anyway.
            onOpenSettings: { [weak self] in
                self?.hover.unpin()
                self?.onOpenSettings()
            },
            onClose: { [weak self] in self?.hover.unpin() },
            onQuit: { NSApp.terminate(nil) }
        )
        let hosting = NSHostingController(rootView: view)
        // AppKit is told nothing about sizing; `resizeToFit` owns it.
        hosting.sizingOptions = []
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
        self.panel = panel
        panel.setContentSize(hosting.view.fittingSize)

        // Zooming and newly arrived usage both change how much room the panel
        // needs. `receive(on:)` defers to a later runloop pass, so the resize
        // never lands inside SwiftUI's own layout.
        contentObserver = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resizeToFit() }

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
