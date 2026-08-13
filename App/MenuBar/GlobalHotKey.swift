import AppKit
import Carbon.HIToolbox

/// A user-configurable shortcut that reveals the pinned panel.
struct HotKeyBinding: Equatable, Codable {
    var keyCode: UInt32
    var modifiers: UInt32
    var displayName: String

    /// ⌥⌘U — unclaimed by macOS, and mnemonic for "usage".
    static let `default` = HotKeyBinding(
        keyCode: UInt32(kVK_ANSI_U),
        modifiers: UInt32(optionKey | cmdKey),
        displayName: "⌥⌘U"
    )

    private static let key = "hotKeyBinding"

    static func load(from defaults: UserDefaults = .standard) -> HotKeyBinding {
        guard let data = defaults.data(forKey: key),
              let binding = try? JSONDecoder().decode(HotKeyBinding.self, from: data) else {
            return .default
        }
        return binding
    }

    static func save(_ binding: HotKeyBinding, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(binding) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Registers the shortcut with the window server.
@MainActor
final class GlobalHotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var onFire: (() -> Void)?

    func register(_ binding: HotKeyBinding, onFire: @escaping () -> Void) {
        unregister()
        self.onFire = onFire

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, context in
                guard let context else { return noErr }
                let key = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async { key.fire() }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )

        let id = EventHotKeyID(signature: OSType(0x4148_4B59), id: 1)
        RegisterEventHotKey(
            binding.keyCode,
            binding.modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &reference
        )
    }

    fileprivate func fire() {
        onFire?()
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil
        handler = nil
    }
}
