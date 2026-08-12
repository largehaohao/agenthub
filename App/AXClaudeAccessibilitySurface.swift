import AppKit
import ApplicationServices
import Foundation

/// Accessibility-backed implementation of `ClaudeAccessibilitySurface`.
///
/// This deliberately reports **no match** unless a window can be identified
/// beyond doubt. Claude Desktop does not currently expose its native session ID
/// or a prompt fingerprint through Accessibility, so exact matching is not
/// possible and AgentHub degrades to activating Claude instead of guessing at a
/// window. Wiring that identification later only requires filling in
/// `snapshot(for:)`; every safety rule already lives in the executor.
struct AXClaudeAccessibilitySurface: ClaudeAccessibilitySurface {
    func matchingWindows(
        bundleID: String,
        sessionNativeID: String
    ) async -> [ClaudeWindowSnapshot] {
        await MainActor.run {
            NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .compactMap { snapshot(for: $0, sessionNativeID: sessionNativeID) }
        }
    }

    func choose(label: String, in window: ClaudeWindowSnapshot) async throws {
        // Unreachable while `snapshot(for:)` cannot identify a window. Kept as a
        // hard stop so a future change cannot silently start clicking.
        throw NativeInteractionError.noMatchingTarget
    }

    func enter(text: String, in window: ClaudeWindowSnapshot) async throws {
        throw NativeInteractionError.noMatchingTarget
    }

    func activate(bundleID: String) async {
        await MainActor.run {
            NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .first?
                .activate(options: [])
        }
    }

    @MainActor
    private func snapshot(
        for application: NSRunningApplication,
        sessionNativeID: String
    ) -> ClaudeWindowSnapshot? {
        // No supported way to prove which window holds `sessionNativeID`, and a
        // wrong window would mean answering a prompt the user never saw.
        nil
    }
}
