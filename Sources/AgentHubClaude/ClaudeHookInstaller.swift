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
    private let executableURL: URL
    private let now: @Sendable () -> Date

    public init(
        settingsURL: URL,
        executableURL: URL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.settingsURL = settingsURL
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
        let settings = (try? loadSettings()) ?? [:]
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
        var settings = try loadSettings()
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
        try writeAtomically(settings)
    }

    public func uninstall() throws {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }

        var settings = try loadSettings()
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
        try writeAtomically(settings)
    }

    private func hookEntry() -> [String: Any] {
        [
            "type": "command",
            "command": executableURL.path,
            "async": true,
            "timeout": Self.hookTimeoutSeconds,
        ]
    }

    private func isOwned(_ entry: [String: Any]) -> Bool {
        guard let command = entry["command"] as? String else { return false }
        let normalized = URL(fileURLWithPath: command)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return normalized == ownedCommand
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

    private func loadSettings() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL), !data.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let settings = object as? [String: Any] else {
            throw ClaudeHookInstallerError.malformedSettings
        }
        return settings
    }

    /// Writes through a sibling staged file so an interrupted write can never
    /// leave the user with truncated Claude settings.
    private func writeAtomically(_ settings: [String: Any]) throws {
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: settings,
                options: [.prettyPrinted, .sortedKeys]
            )
        } catch {
            throw ClaudeHookInstallerError.malformedSettings
        }

        let directory = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let staged = directory.appendingPathComponent(
            ".\(settingsURL.lastPathComponent).agenthub-\(UUID().uuidString)"
        )
        do {
            try data.write(to: staged, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: staged.path
            )

            if FileManager.default.fileExists(atPath: settingsURL.path) {
                _ = try FileManager.default.replaceItemAt(settingsURL, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: settingsURL)
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: settingsURL.path
            )
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw ClaudeHookInstallerError.settingsNotWritable
        }
    }
}
