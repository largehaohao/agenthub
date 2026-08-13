import Foundation

/// Removes what earlier versions of AgentHub installed on this Mac.
///
/// Ownership is decided by a command resolving to an AgentHub helper, so hooks
/// belonging to other tools are never touched. Every file is backed up before
/// it is rewritten.
struct LegacyUninstaller {
    struct Summary {
        let removedClaudeHooks: Int
        let removedCursorHooks: Int
        let removedLaunchAgent: Bool
    }

    private let claudeSettingsURL: URL
    private let cursorHooksURL: URL
    private let launchAgentURL: URL

    init(claudeSettingsURL: URL, cursorHooksURL: URL, launchAgentURL: URL) {
        self.claudeSettingsURL = claudeSettingsURL
        self.cursorHooksURL = cursorHooksURL
        self.launchAgentURL = launchAgentURL
    }

    static func standard() -> LegacyUninstaller {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return LegacyUninstaller(
            claudeSettingsURL: home.appendingPathComponent(".claude/settings.json"),
            cursorHooksURL: home.appendingPathComponent(".cursor/hooks.json"),
            launchAgentURL: home.appendingPathComponent(
                "Library/LaunchAgents/com.agenthub.daemon.plist"
            )
        )
    }

    func run() throws -> Summary {
        Summary(
            removedClaudeHooks: try cleanClaude(),
            removedCursorHooks: try cleanCursor(),
            removedLaunchAgent: removeLaunchAgent()
        )
    }

    /// True only for a command that runs one of AgentHub's own helpers.
    private func isOwned(_ command: String) -> Bool {
        command.contains("agenthub-claude-hook")
            || command.contains("agenthub-claude-statusline")
            || command.contains("agenthub-cursor-hook")
    }

    private func cleanClaude() throws -> Int {
        guard var root = try loadObject(claudeSettingsURL) else { return 0 }
        try backup(claudeSettingsURL)
        var removed = 0

        // A status line the user wrote themselves stays; only the wrapper that
        // pipes through AgentHub's reporter is ours to remove.
        if let statusLine = root["statusLine"] as? [String: Any],
           let command = statusLine["command"] as? String,
           isOwned(command) {
            root.removeValue(forKey: "statusLine")
        }

        if let hooks = root["hooks"] as? [String: Any] {
            var cleaned: [String: Any] = [:]
            for (event, value) in hooks {
                guard let matchers = value as? [[String: Any]] else {
                    cleaned[event] = value
                    continue
                }
                let remaining: [[String: Any]] = matchers.compactMap { matcher in
                    var matcher = matcher
                    guard let entries = matcher["hooks"] as? [[String: Any]] else { return matcher }
                    let kept = entries.filter { entry in
                        guard let command = entry["command"] as? String else { return true }
                        if isOwned(command) {
                            removed += 1
                            return false
                        }
                        return true
                    }
                    // A matcher AgentHub emptied, carrying nothing else, goes
                    // rather than lingering as an empty shell.
                    if kept.isEmpty && matcher.count == 1 { return nil }
                    matcher["hooks"] = kept
                    return matcher
                }
                if !remaining.isEmpty { cleaned[event] = remaining }
            }
            if cleaned.isEmpty {
                root.removeValue(forKey: "hooks")
            } else {
                root["hooks"] = cleaned
            }
        }

        try write(root, to: claudeSettingsURL)
        return removed
    }

    private func cleanCursor() throws -> Int {
        guard var root = try loadObject(cursorHooksURL) else { return 0 }
        try backup(cursorHooksURL)
        var removed = 0

        if let hooks = root["hooks"] as? [String: Any] {
            var cleaned: [String: Any] = [:]
            for (event, value) in hooks {
                guard let entries = value as? [[String: Any]] else {
                    cleaned[event] = value
                    continue
                }
                let kept = entries.filter { entry in
                    guard let command = entry["command"] as? String else { return true }
                    if isOwned(command) {
                        removed += 1
                        return false
                    }
                    return true
                }
                if !kept.isEmpty { cleaned[event] = kept }
            }
            root["hooks"] = cleaned
        }

        try write(root, to: cursorHooksURL)
        return removed
    }

    private func removeLaunchAgent() -> Bool {
        guard FileManager.default.fileExists(atPath: launchAgentURL.path) else { return false }
        // Best effort: the job may already be unloaded, which is not a failure.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())/com.agenthub.daemon"]
        try? process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: launchAgentURL)
        return true
    }

    private func loadObject(_ url: URL) throws -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func backup(_ url: URL) throws {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let destination = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).agenthub-backup-\(stamp)")
        try? FileManager.default.copyItem(at: url, to: destination)
    }

    private func write(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }
}
