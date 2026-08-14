import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The shortcut Settings edits, and the live registration behind it.
@MainActor
final class HotKeyModel: ObservableObject {
    @Published private(set) var binding: HotKeyBinding
    @Published var isRecording = false

    /// Re-registers with the window server. Set by the app delegate, which owns
    /// the `GlobalHotKey`.
    var onChange: ((HotKeyBinding) -> Void)?

    init(binding: HotKeyBinding = .load()) {
        self.binding = binding
    }

    func record(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> Bool {
        guard let candidate = HotKeyBinding.from(
            keyCode: keyCode,
            flags: flags,
            characters: characters
        ) else {
            return false
        }
        apply(candidate)
        return true
    }

    func resetToDefault() {
        apply(.default)
    }

    private func apply(_ candidate: HotKeyBinding) {
        binding = candidate
        HotKeyBinding.save(candidate)
        onChange?(candidate)
        isRecording = false
    }
}

/// Click to record, then press the shortcut.
struct HotKeyRecorder: View {
    @ObservedObject var model: HotKeyModel

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.isRecording.toggle()
            } label: {
                Text(model.isRecording ? "Press a shortcut…" : model.binding.displayName)
                    .monospaced()
                    .frame(minWidth: 120)
            }
            .background(RecorderCatcher(model: model))

            Button("Reset") { model.resetToDefault() }
                .disabled(model.binding == .default)
        }
        // Leaving the pane while recording would strand the event monitor,
        // which swallows every key press.
        .onDisappear { model.isRecording = false }
    }
}

/// Captures the next key press while recording.
///
/// A local event monitor is used rather than first-responder handling: the
/// Settings window hosts an ordinary SwiftUI button, and the shortcut being
/// recorded is frequently one AppKit would otherwise route to a menu.
private struct RecorderCatcher: NSViewRepresentable {
    @ObservedObject var model: HotKeyModel

    func makeNSView(context: Context) -> NSView {
        context.coordinator.model = model
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.model = model
        context.coordinator.setRecording(model.isRecording)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        var model: HotKeyModel?
        private var monitor: Any?

        func setRecording(_ recording: Bool) {
            guard recording != (monitor != nil) else { return }
            recording ? start() : stop()
        }

        private func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self, let model = self.model else { return event }
                if event.keyCode == UInt16(kVK_Escape) {
                    model.isRecording = false
                    self.stop()
                    return nil
                }
                let recorded = model.record(
                    keyCode: event.keyCode,
                    flags: event.modifierFlags,
                    characters: event.charactersIgnoringModifiers
                )
                // A bare key is swallowed rather than accepted, so the field
                // keeps waiting instead of binding something unusable.
                if recorded { self.stop() }
                return nil
            }
        }

        private func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
