import AppKit
import Carbon.HIToolbox

/// A user-configurable shortcut that reveals the pinned panel.
struct HotKeyBinding: Equatable, Codable {
    var keyCode: UInt32
    var modifiers: UInt32
    var displayName: String

    /// ⇧⌘T — unclaimed by macOS.
    static let `default` = HotKeyBinding(
        keyCode: UInt32(kVK_ANSI_T),
        modifiers: UInt32(cmdKey | shiftKey),
        displayName: "⇧⌘T"
    )

    private static let key = "hotKeyBinding"

    /// Builds a binding from a key event's raw parts.
    ///
    /// - Returns: nil when no modifier is held. A global hot key with no
    ///   modifier would swallow that key in every application.
    static func from(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        characters: String?
    ) -> HotKeyBinding? {
        var carbon: UInt32 = 0
        var symbols = ""
        // Ordered as macOS renders shortcuts, not as the flags are declared.
        if flags.contains(.control) { carbon |= UInt32(controlKey); symbols += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); symbols += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); symbols += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); symbols += "⌘" }
        guard carbon != 0 else { return nil }

        return HotKeyBinding(
            keyCode: UInt32(keyCode),
            modifiers: carbon,
            displayName: symbols + keyName(keyCode: keyCode, characters: characters)
        )
    }

    /// The named keys have no printable character, so they cannot come from the
    /// event's own text.
    private static func keyName(keyCode: UInt16, characters: String?) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default: break
        }
        if let characters, let first = characters.first, !first.isWhitespace {
            return String(first).uppercased()
        }
        return "Key \(keyCode)"
    }

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
