import AppKit
import Foundation

@MainActor
protocol JumpOpening {
    func open(bundleID: String, windowHint: String?) async throws
}

enum JumpOpeningError: Error, Equatable {
    case applicationNotFound(String)
}

@MainActor
struct WorkspaceJumpOpener: JumpOpening {
    /// Verified on macOS via `osascript -e 'id of app "Cursor"'`.
    static let cursorBundleID = "com.todesktop.230313mzl4w4u92"

    func open(bundleID: String, windowHint: String?) async throws {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleID
        ) else {
            throw JumpOpeningError.applicationNotFound(bundleID)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        if bundleID == Self.cursorBundleID,
           let hint = windowHint,
           !hint.isEmpty,
           FileManager.default.fileExists(atPath: hint) {
            let workspaceURL = URL(fileURLWithPath: hint, isDirectory: true)
            _ = try await NSWorkspace.shared.open(
                [workspaceURL],
                withApplicationAt: applicationURL,
                configuration: configuration
            )
            return
        }

        _ = try await NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: configuration
        )
    }
}
