import Foundation

/// Resolves the daemon socket for one-shot helper executables.
///
/// macOS derives Application Support from the user record rather than `HOME`,
/// so without an explicit override there is no way to point a helper at a test
/// daemon — the only reachable socket would be the user's live one. The
/// override exists so real delivery can be verified against a throwaway daemon.
public enum DaemonSocketPath {
    public static let overrideVariable = "AGENTHUB_SOCKET"

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> String {
        if let override = environment[overrideVariable], !override.isEmpty {
            return override
        }

        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return applicationSupport
            .appendingPathComponent("AgentHub", isDirectory: true)
            .appendingPathComponent("agenthub.sock")
            .path
    }
}
