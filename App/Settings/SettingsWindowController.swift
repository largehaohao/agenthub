import AppKit
import SwiftUI

/// Owns the settings window.
///
/// SwiftUI's `Settings` scene is opened by sending `showSettingsWindow:` into
/// the responder chain, which relies on the menu item that scene installs in the
/// app menu. An accessory app has no menu bar, so nothing responds and the
/// action is silently dropped — settings could not be opened at all, and no
/// error said so. Owning an `NSWindow` removes the dependency on that plumbing
/// and on the selector's name, which has changed between macOS releases.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let title: String
    private let makeContent: @MainActor () -> AnyView
    private var window: NSWindow?

    init(title: String = "AgentHub Settings", makeContent: @escaping @MainActor () -> AnyView) {
        self.title = title
        self.makeContent = makeContent
        super.init()
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window

        // An accessory app is not active, so its window would open behind
        // whatever the user is looking at and never take the keyboard.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: makeContent())
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(hosting.view.fittingSize)
        window.center()
        return window
    }

    /// Kept rather than torn down, so reopening returns to the same window in
    /// the same place.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
