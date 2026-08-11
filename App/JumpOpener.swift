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
    func open(bundleID: String, windowHint: String?) async throws {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleID
        ) else {
            throw JumpOpeningError.applicationNotFound(bundleID)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: configuration
        )
    }
}
