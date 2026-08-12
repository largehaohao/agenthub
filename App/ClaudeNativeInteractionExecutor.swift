import AppKit
import Foundation
import AgentHubCore

public enum NativeInteractionError: Error, Equatable, Sendable {
    case accessibilityUnavailable
    case noMatchingTarget
    case ambiguousTarget
    case stalePrompt
}

/// What a Claude window is currently displaying, read through Accessibility.
public struct ClaudeWindowSnapshot: Equatable, Sendable {
    public let sessionNativeID: String
    public let promptFingerprint: String
    public let visibleOptions: [String]

    public init(
        sessionNativeID: String,
        promptFingerprint: String,
        visibleOptions: [String]
    ) {
        self.sessionNativeID = sessionNativeID
        self.promptFingerprint = promptFingerprint
        self.visibleOptions = visibleOptions
    }
}

/// The Accessibility operations the executor needs. Kept behind a protocol so
/// the safety rules can be tested without granting real Accessibility access.
public protocol ClaudeAccessibilitySurface: Sendable {
    func matchingWindows(bundleID: String, sessionNativeID: String) async -> [ClaudeWindowSnapshot]
    func choose(label: String, in window: ClaudeWindowSnapshot) async throws
    func enter(text: String, in window: ClaudeWindowSnapshot) async throws
    func activate(bundleID: String) async
}

public protocol NativeInteractionExecuting: Sendable {
    func execute(_ plan: NativeInteractionPlan) async throws
}

/// Performs a Claude Desktop UI action only when the live UI can be matched
/// exactly.
///
/// Every uncertainty — no permission, no match, more than one match, a changed
/// prompt, or an option that is not actually on screen — results in zero clicks,
/// pastes, or submissions. The app falls back to activating Claude so the user
/// can act natively, and never reports an exact interaction after a fallback.
public struct ClaudeNativeInteractionExecutor: NativeInteractionExecuting {
    private let surface: any ClaudeAccessibilitySurface
    private let isTrusted: @Sendable () -> Bool

    public init(
        surface: any ClaudeAccessibilitySurface,
        isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }
    ) {
        self.surface = surface
        self.isTrusted = isTrusted
    }

    public func execute(_ plan: NativeInteractionPlan) async throws {
        guard plan.provider == .claude else {
            throw NativeInteractionError.noMatchingTarget
        }

        // Without Accessibility there is no way to verify the UI, so the only
        // safe action is to bring Claude forward for the user.
        guard isTrusted() else {
            await surface.activate(bundleID: plan.bundleID)
            throw NativeInteractionError.accessibilityUnavailable
        }

        let windows = await surface.matchingWindows(
            bundleID: plan.bundleID,
            sessionNativeID: plan.sessionNativeID
        )
        guard !windows.isEmpty else {
            throw NativeInteractionError.noMatchingTarget
        }
        guard windows.count == 1, let window = windows.first else {
            throw NativeInteractionError.ambiguousTarget
        }

        // Re-read the live prompt: the request may have been raised against a
        // screen Claude has since moved past.
        guard window.promptFingerprint == plan.promptFingerprint else {
            throw NativeInteractionError.stalePrompt
        }

        switch plan.operation {
        case .choose(let label):
            // Only ever select something the user can actually see.
            guard window.visibleOptions.contains(label) else {
                throw NativeInteractionError.noMatchingTarget
            }
            try await surface.choose(label: label, in: window)

        case .enter(let text):
            try await surface.enter(text: text, in: window)
        }
    }
}
