import SwiftUI
import AgentHubQuota

@main
struct AgentHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// AgentHub has no window of its own — the panel and the settings window are
    /// both AppKit-owned. `App` still requires a scene, and an empty `Settings`
    /// is the one that adds no menu item and no window.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let uninstallKey = "legacyUninstallCompleted"

    let cursorAuthorization = CursorAuthorizationModel()
    let hotKeyModel = HotKeyModel()
    let providerVisibility = ProviderVisibility()

    private lazy var model = QuotaPanelModel(
        service: QuotaService.live(shown: providerVisibility.shown)
    )
    private lazy var settingsWindow = SettingsWindowController { [self] in
        AnyView(
            SettingsView(
                cursor: cursorAuthorization,
                hotKey: hotKeyModel,
                providers: providerVisibility
            )
        )
    }
    private lazy var menuBar = MenuBarController(model: model) { [weak self] in
        self?.settingsWindow.show()
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

        let service = model.service
        providerVisibility.onChange = { [weak self] shown in
            Task {
                await service.show(shown)
                await self?.model.load(force: true)
            }
        }

        bind(hotKeyModel.binding)
        hotKeyModel.onChange = { [weak self] binding in
            self?.bind(binding)
        }

        refreshTask = Task { [model] in
            while !Task.isCancelled {
                await model.load(force: false)
                try? await Task.sleep(for: .seconds(QuotaService.defaultInterval))
            }
        }
    }

    private func bind(_ binding: HotKeyBinding) {
        hotKey.register(binding) { [weak self] in
            self?.menuBar.togglePinned()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTask?.cancel()
        hotKey.unregister()
    }
}
