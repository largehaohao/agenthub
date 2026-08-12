import Foundation
import AgentHubCore

/// Installs AgentHub's usage reporter as the Claude `statusLine` command.
///
/// Claude Code supports exactly one status line, and many users already have
/// their own. Installing therefore *wraps* rather than replaces: AgentHub's
/// reporter is fed the payload first, then the user's original command runs and
/// still owns everything displayed. Uninstalling restores the original command
/// byte-for-byte, or removes the key entirely when AgentHub introduced it.
public struct ClaudeStatusLineInstaller: Sendable {
    /// Marks the wrapper so it can be recognized, refreshed, and unwrapped
    /// without ever guessing at the user's own command.
    static let marker = "# agenthub-statusline"

    private let store: ClaudeSettingsStore
    private let executableURL: URL
    private let now: @Sendable () -> Date

    public init(
        settingsURL: URL,
        executableURL: URL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = ClaudeSettingsStore(settingsURL: settingsURL)
        self.executableURL = executableURL
        self.now = now
    }

    private var reporterPath: String {
        executableURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    public func status() throws -> ProviderComponentStatus {
        let settings = (try? store.load()) ?? [:]
        let installed = command(in: settings).map(isOwned) ?? false

        return ProviderComponentStatus(
            provider: .claude,
            component: "statusline",
            available: installed,
            version: nil,
            path: installed ? reporterPath : nil,
            message: installed
                ? nil
                : "Install the usage reporter to see Claude limits.",
            changedAt: now()
        )
    }

    public func install() throws {
        var settings = try store.load()
        let existing = command(in: settings)

        // Reinstalling must refresh the wrapper, never nest one inside another,
        // so always unwrap first and re-wrap the user's real command.
        let userCommand = existing.map(unwrapped) ?? nil

        var statusLine = settings["statusLine"] as? [String: Any] ?? [:]
        statusLine["type"] = "command"
        statusLine["command"] = wrapped(userCommand)
        settings["statusLine"] = statusLine

        try store.write(settings)
    }

    public func uninstall() throws {
        guard FileManager.default.fileExists(atPath: store.settingsURL.path) else { return }

        var settings = try store.load()
        guard let existing = command(in: settings), isOwned(existing) else {
            // Not ours: a third-party status line is left exactly as it is.
            return
        }

        if let userCommand = unwrapped(existing) {
            var statusLine = settings["statusLine"] as? [String: Any] ?? [:]
            statusLine["type"] = "command"
            statusLine["command"] = userCommand
            settings["statusLine"] = statusLine
        } else {
            // AgentHub introduced the key, so removing it restores the original
            // state rather than leaving an empty status line behind.
            settings.removeValue(forKey: "statusLine")
        }

        try store.write(settings)
    }

    private func command(in settings: [String: Any]) -> String? {
        (settings["statusLine"] as? [String: Any])?["command"] as? String
    }

    private func isOwned(_ command: String) -> Bool {
        command.contains(Self.marker) && command.contains(reporterPath)
    }

    /// Tees the payload to AgentHub's reporter, then hands the identical bytes
    /// to the user's own command. The reporter never writes to stdout, so it
    /// cannot disturb what Claude renders, and a reporter failure is swallowed
    /// so the user's status line keeps working.
    private func wrapped(_ userCommand: String?) -> String {
        let report = "payload=$(cat); printf '%s' \"$payload\" "
            + "| '\(reporterPath)' >/dev/null 2>&1 || true"

        guard let userCommand, !userCommand.isEmpty else {
            return "\(Self.marker)\n\(report)"
        }
        return "\(Self.marker)\n\(report); printf '%s' \"$payload\" | \(userCommand)"
    }

    /// Recovers the user's original command from a wrapper, or nil when
    /// AgentHub introduced the status line itself.
    private func unwrapped(_ command: String) -> String? {
        guard isOwned(command) else { return command }
        guard let range = command.range(of: "|| true; printf '%s' \"$payload\" | ") else {
            return nil
        }
        let user = String(command[range.upperBound...])
        return user.isEmpty ? nil : user
    }
}
