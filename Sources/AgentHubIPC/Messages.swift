import Foundation
import AgentHubCore

public let agentHubIPCProtocolVersion = 2

public struct IPCEnvelope<Body: Codable & Sendable>: Codable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let body: Body

    public init(
        protocolVersion: Int = agentHubIPCProtocolVersion,
        requestID: UUID = UUID(),
        body: Body
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.body = body
    }
}

public enum DaemonCommand: Codable, Sendable {
    case getSnapshot
    case launch(Provider, LaunchRequest)
    case attachEndpoint(ProviderEndpointAttachment)
    case authenticateEndpoint(ProviderEndpointCredentialBinding)
    case detachEndpoint(provider: Provider, id: String)
    case resolveRequest(UUID, RequestDecision)
    case sendInput(UUID, AgentInput)
    case createHandoff(source: UUID, target: UUID, turnLimit: Int, note: String?)
    case jumpTarget(UUID)
}

public enum DaemonReply: Codable, Equatable, Sendable {
    case snapshot(AgentHubState)
    case accepted(UUID)
    case endpoint(ProviderEndpoint)
    case completed
    case jump(JumpTarget)
    case failure(String)
}

public enum DaemonEvent: Codable, Equatable, Sendable {
    case stateChanged(sequence: UInt64)
    case adapterHealth(Provider, AdapterHealth)
}

enum WireBody: Codable, Sendable {
    case reply(DaemonReply)
    case event(DaemonEvent)
}

public enum IPCError: Error, Equatable, Sendable {
    case oversizedFrame
    case unsupportedProtocolVersion(Int)
    case disconnected
    case invalidSocketPermissions(Int)
}

public enum ReconnectSchedule {
    public static let delays: [TimeInterval] = [1, 2, 4, 8, 16, 32, 60]
}
