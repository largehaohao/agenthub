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
    let cursorAuthorization = CursorAuthorizationModel()

    private lazy var model = QuotaPanelModel(service: QuotaService.live())
    private lazy var menuBar = MenuBarController(model: model) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
    private let hotKey = GlobalHotKey()
    private var refreshTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
