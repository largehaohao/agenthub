import Foundation
import AgentHubIPC

/// Resolves the daemon socket for the one-shot Claude helpers.
///
/// Delegates to `DaemonSocketPath` so Cursor and Claude helpers share one
/// override contract (`AGENTHUB_SOCKET`).
public enum ClaudeHelperSocket {
    public static let overrideVariable = DaemonSocketPath.overrideVariable

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> String {
        try DaemonSocketPath.resolve(environment: environment, fileManager: fileManager)
    }
}
