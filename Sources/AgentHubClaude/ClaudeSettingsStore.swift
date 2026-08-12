import Foundation

/// Reads and writes the user's Claude settings file safely.
///
/// Shared by every installer that owns entries in that file, so the
/// parse-copy-validate-atomic-replace discipline exists in exactly one place:
/// unrelated keys are preserved, malformed JSON leaves the original bytes
/// untouched, and an interrupted write can never truncate the user's settings.
struct ClaudeSettingsStore: Sendable {
    let settingsURL: URL

    func load() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL), !data.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let settings = object as? [String: Any] else {
            throw ClaudeHookInstallerError.malformedSettings
        }
        return settings
    }

    /// Writes through a sibling staged file, then replaces the original.
    func write(_ settings: [String: Any]) throws {
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
