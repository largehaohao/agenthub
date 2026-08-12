import Foundation
import AgentHubCore

/// Maps AgentHub hook permission decisions to Cursor's synchronous stdout JSON.
public enum CursorPermissionGate: Sendable {
    public static let defaultTimeoutMilliseconds = 25_000

    public static func responseJSON(for decision: HookPermissionDecision) -> Data {
        let object: [String: String] = ["permission": decision.rawValue]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    public static func decision(from requestDecision: RequestDecision) -> HookPermissionDecision {
        switch requestDecision {
        case .accept, .acceptForSession:
            return .allow
        case .decline, .cancel:
            return .deny
        case .text, .choices, .answers:
            // Free-text / choice resolutions are not shell/MCP allow bits.
            return .ask
        }
    }
}
