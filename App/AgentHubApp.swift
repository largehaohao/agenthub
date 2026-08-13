import SwiftUI
import AgentHubQuota

@main
struct AgentHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView(cursor: delegate.cursorAuthorization)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let uninstallKey = "legacyUninstallCompleted"

    let cursorAuthorization = CursorAuthorizationModel()

    private lazy var model = QuotaPanelModel(service: QuotaService.live())
    private lazy var menuBar = MenuBarController(model: model) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
    private let hotKey = GlobalHotKey()
    private var refreshTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Earlier versions installed a daemon and provider hooks. Removing them
        // once is part of the migration; afterwards this is a no-op.
        if !UserDefaults.standard.bool(forKey: Self.uninstallKey) {
            _ = try? LegacyUninstaller.standard().run()
            UserDefaults.standard.set(true, forKey: Self.uninstallKey)
        }

        menuBar.install()

        hotKey.register(HotKeyBinding.load()) { [weak self] in
            self?.menuBar.revealPinned()
        }

        refreshTask = Task { [model] in
            while !Task.isCancelled {
                await model.load(force: false)
                try? await Task.sleep(for: .seconds(QuotaService.defaultInterval))
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTask?.cancel()
        hotKey.unregister()
    }
}
