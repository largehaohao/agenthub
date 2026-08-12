import Foundation
import AgentHubCore

public enum CursorHookInstallerError: Error, Equatable, Sendable {
    case malformedHooksFile
    case hooksFileNotWritable
}

/// Owns only AgentHub entries in a Cursor `hooks.json` file.
///
/// Cursor's schema is `{ "version": 1, "hooks": { "<event>": [ { "command": ... } ] } }`.
/// Install merges absolute helper commands beside existing entries (including
/// OpenIsland). Uninstall removes only commands whose path matches AgentHub's
/// helper exactly.
public struct CursorHookInstaller: Sendable {
    /// Events registered for the first Cursor slice.
    public static let observedEvents = [
        "sessionStart",
        "sessionEnd",
        "beforeSubmitPrompt",
        "stop",
        "beforeShellExecution",
        "afterShellExecution",
        "beforeMCPExecution",
        "afterMCPExecution",
        "subagentStart",
        "subagentStop",
        "afterAgentResponse",
        "afterAgentThought",
        "preCompact",
    ]

    /// Decision hooks that should fail closed when AgentHub's own hook crashes.
    private static let failClosedEvents: Set<String> = [
        "beforeShellExecution",
        "beforeMCPExecution",
    ]

    /// Budget for decision hooks waiting on AgentHub; observation hooks finish faster.
    static let hookTimeoutSeconds = 30

    private let hooksURL: URL
    private let executableURL: URL
    private let now: @Sendable () -> Date

    public init(
        hooksURL: URL,
        executableURL: URL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.hooksURL = hooksURL
        self.executableURL = executableURL
        self.now = now
    }

    private var ownedCommand: String {
        executableURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    public func status() throws -> ProviderComponentStatus {
        let root = (try? load()) ?? [:]
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        let installed = Self.observedEvents.allSatisfy { event in
            !ownedEntries(in: hooks, event: event).isEmpty
        }

        return ProviderComponentStatus(
            provider: .cursor,
            component: "hooks",
            available: installed,
            version: nil,
            path: installed ? executableURL.path : nil,
            message: installed ? nil : "AgentHub Cursor hooks are not installed",
            changedAt: now()
        )
    }

    public func install() throws {
        var root = try load()
        if root["version"] == nil {
            root["version"] = 1
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        for event in Self.observedEvents {
            var entries = hooks[event] as? [[String: Any]] ?? []
            entries = entries.filter { !isOwned($0) }
            entries.append(hookEntry(for: event))
            hooks[event] = entries
        }

        root["hooks"] = hooks
        try write(root)
    }

    public func uninstall() throws {
        guard FileManager.default.fileExists(atPath: hooksURL.path) else { return }

        var root = try load()
        guard var hooks = root["hooks"] as? [String: Any] else { return }

        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            let retained = entries.filter { !isOwned($0) }
            if retained.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = retained
            }
        }

        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        try write(root)
    }

    private func hookEntry(for event: String) -> [String: Any] {
        var entry: [String: Any] = [
            "command": ownedCommand,
            "timeout": Self.hookTimeoutSeconds,
        ]
        if Self.failClosedEvents.contains(event) {
            entry["failClosed"] = true
        }
        return entry
    }

    private func isOwned(_ entry: [String: Any]) -> Bool {
        guard let command = entry["command"] as? String else { return false }
        // Exact absolute helper path only — argument-bearing peers are foreign.
        let normalized = URL(fileURLWithPath: command)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return normalized == ownedCommand
    }

    private func ownedEntries(
        in hooks: [String: Any],
        event: String
    ) -> [[String: Any]] {
        guard let entries = hooks[event] as? [[String: Any]] else { return [] }
        return entries.filter(isOwned)
    }

    private func load() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: hooksURL), !data.isEmpty else {
            return ["version": 1]
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw CursorHookInstallerError.malformedHooksFile
        }
        return root
    }

    private func write(_ root: [String: Any]) throws {
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys]
            )
        } catch {
            throw CursorHookInstallerError.malformedHooksFile
        }

        let directory = hooksURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let staged = directory.appendingPathComponent(
            ".\(hooksURL.lastPathComponent).agenthub-\(UUID().uuidString)"
        )
        do {
            try data.write(to: staged, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: staged.path
            )
            if FileManager.default.fileExists(atPath: hooksURL.path) {
                _ = try FileManager.default.replaceItemAt(hooksURL, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: hooksURL)
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: hooksURL.path
            )
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw CursorHookInstallerError.hooksFileNotWritable
        }
    }
}
