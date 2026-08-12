import Foundation
import AgentHubCore

public enum ClaudeHookInstallerError: Error, Equatable, Sendable {
    /// The existing settings file is not a JSON object. The file is left byte-identical.
    case malformedSettings
    case settingsNotWritable
}

/// Owns only AgentHub's entries in the user's Claude settings file.
///
/// Install parses the existing JSON, merges hook commands into a copy, and
/// atomically replaces the file, so unrelated settings, unknown keys, and
/// third-party hooks are preserved. Uninstall removes entries only when the
/// command resolves to exactly AgentHub's hook executable.
public struct ClaudeHookInstaller: Sendable {
    /// Events the first slice observes. `CwdChanged` is registered when Claude
    /// emits it; unknown events decode to `.unknown` rather than failing.
    public static let observedEvents = [
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "Stop",
        "StopFailure",
        "PreToolUse",
        "PostToolUse",
        "PermissionRequest",
        "PermissionDenied",
        "Notification",
        "SubagentStart",
        "SubagentStop",
        "TaskCreated",
        "TaskCompleted",
        "TeammateIdle",
        "CwdChanged",
    ]

    /// Keeps Claude responsive if the daemon is unavailable; the bridge itself
    /// also exits quickly rather than blocking on the socket.
    static let hookTimeoutSeconds = 5

    private let settingsURL: URL
    private let store: ClaudeSettingsStore
    private let executableURL: URL
    private let now: @Sendable () -> Date

    public init(
        settingsURL: URL,
        executableURL: URL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.settingsURL = settingsURL
        self.store = ClaudeSettingsStore(settingsURL: settingsURL)
        self.executableURL = executableURL
        self.now = now
    }

    /// The canonical path AgentHub owns. Comparisons normalize `.`/`..` and
    /// symlink-free spellings so an equivalent path is still recognized, while a
    /// different executable or an argument-bearing command never matches.
    private var ownedCommand: String {
        executableURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    public func status() throws -> ProviderComponentStatus {
        let settings = (try? store.load()) ?? [:]
        let installed = Self.observedEvents.allSatisfy { event in
            !ownedEntries(in: settings, event: event).isEmpty
        }

        return ProviderComponentStatus(
            provider: .claude,
            component: "hooks",
            available: installed,
            version: nil,
            path: installed ? executableURL.path : nil,
            message: installed ? nil : "AgentHub Claude hooks are not installed",
            changedAt: now()
        )
    }

    public func install() throws {
        var settings = try store.load()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for event in Self.observedEvents {
            var matchers = hooks[event] as? [[String: Any]] ?? []

            // Drop any prior AgentHub entry first so reinstalling cannot
            // accumulate duplicates, then append exactly one fresh entry.
            matchers = matchers.compactMap { matcher in
                var matcher = matcher
                guard let entries = matcher["hooks"] as? [[String: Any]] else { return matcher }
                let retained = entries.filter { !isOwned($0) }
                if retained.isEmpty && entries.count > 0 && matcher.count == 1 {
                    return nil
                }
                matcher["hooks"] = retained
                return matcher
            }

            matchers.append(["hooks": [hookEntry()]])
            hooks[event] = matchers
        }

        settings["hooks"] = hooks
        try store.write(settings)
    }

    public func uninstall() throws {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }

        var settings = try store.load()
        guard var hooks = settings["hooks"] as? [String: Any] else { return }

        for (event, value) in hooks {
            guard let matchers = value as? [[String: Any]] else { continue }

            let remaining: [[String: Any]] = matchers.compactMap { matcher in
                var matcher = matcher
                guard let entries = matcher["hooks"] as? [[String: Any]] else { return matcher }
                let retained = entries.filter { !isOwned($0) }
                // Remove a matcher only when AgentHub emptied it and it carried
                // nothing else; a matcher with its own keys is preserved.
                if retained.isEmpty && matcher.count == 1 { return nil }
                matcher["hooks"] = retained
                return matcher
            }

            if remaining.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = remaining
            }
        }

        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
        try store.write(settings)
    }

    private func hookEntry() -> [String: Any] {
        [
            "type": "command",
            "command": Self.shellQuoted(executableURL.path),
            "async": true,
            "timeout": Self.hookTimeoutSeconds,
        ]
    }

    /// Claude runs hook commands through a shell, so a helper under
    /// `~/Library/Application Support/...` splits on its space and exits 127
    /// unless the path is quoted.
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func isOwned(_ entry: [String: Any]) -> Bool {
        guard let command = entry["command"] as? String,
              let executable = Self.executablePath(
                  fromCommand: command,
                  matching: ownedCommand
              ) else { return false }
        let normalized = URL(fileURLWithPath: executable)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return normalized == ownedCommand
    }

    /// Resolves a command to the bare executable path AgentHub may own.
    ///
    /// A fully quoted path is unwrapped, and a legacy unquoted entry written
    /// before quoting is still recognized so reinstalling replaces it rather
    /// than accumulating a broken duplicate. An argument-bearing command never
    /// matches: `<ours> --flag` belongs to whoever added the flag, so returning
    /// its first token would let uninstall delete a third-party hook.
    /// - Parameter owned: when supplied, an unquoted command equal to this exact
    ///   path is accepted even though it contains spaces. That is the legacy
    ///   `Application Support` entry written before quoting. Any longer command
    ///   sharing that prefix carries arguments and is left alone.
    static func executablePath(
        fromCommand command: String,
        matching owned: String? = nil
    ) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let quoted = Self.fullyQuotedPath(trimmed, delimiter: "'")
            ?? Self.fullyQuotedPath(trimmed, delimiter: "\"") {
            return quoted
        }

        // A legacy unquoted entry is ours only when it equals our path exactly.
        if let owned, trimmed == owned { return trimmed }

        // Otherwise only a bare, argument-free path can be ours.
        guard !trimmed.contains(where: { $0.isWhitespace }) else { return nil }
        return trimmed
    }

    /// Returns the path only when the quotes wrap the entire command, so a
    /// quoted path followed by arguments is not claimed.
    private static func fullyQuotedPath(
        _ command: String,
        delimiter: Character
    ) -> String? {
        guard command.first == delimiter, command.last == delimiter, command.count >= 2 else {
            return nil
        }
        let path = String(command.dropFirst().dropLast())
        guard !path.isEmpty, !path.contains(delimiter) else { return nil }
        return path
    }

    private func ownedEntries(
        in settings: [String: Any],
        event: String
    ) -> [[String: Any]] {
        guard let hooks = settings["hooks"] as? [String: Any],
              let matchers = hooks[event] as? [[String: Any]] else { return [] }
        return matchers
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .filter(isOwned)
    }
}
