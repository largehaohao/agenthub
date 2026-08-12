import Foundation
import AgentHubCore

/// Which Claude surface produced an observation.
public enum ClaudeSurface: String, Equatable, Sendable {
    case managedCLI = "Managed CLI"
    case externalCLI = "External CLI"
    case desktop = "Desktop"
}

/// Classifies a Claude hook by its reported process ancestry.
///
/// Classification is deliberately conservative: only a Claude application
/// ancestor counts as Desktop, and only a UUID AgentHub itself registered
/// counts as managed. Anything else is an external CLI with reduced capability,
/// so AgentHub never claims control it cannot validate.
public struct ClaudeProcessClassifier: Sendable {
    /// The macOS bundle path fragment for Claude Desktop. Matching the
    /// `Claude.app/Contents/MacOS` prefix avoids treating a similarly named
    /// third-party application as Desktop.
    static let desktopExecutableFragment = "Claude.app/Contents/MacOS"

    public init() {}

    public func surface(
        for ancestors: [ProcessObservation],
        managedSessionIDs: Set<UUID>,
        claudeSessionID: UUID? = nil
    ) -> ClaudeSurface {
        if ancestors.contains(where: { $0.command.contains(Self.desktopExecutableFragment) }) {
            return .desktop
        }

        if let claudeSessionID,
           managedSessionIDs.contains(claudeSessionID),
           ancestors.contains(where: { $0.command.contains("tmux") }) {
            return .managedCLI
        }

        return .externalCLI
    }
}
