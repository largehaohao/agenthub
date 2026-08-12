import Foundation

public protocol AgentAdapter: Sendable {
    var provider: Provider { get }

    func capabilities() async -> [Capability: ReliabilityLevel]
    func launch(_ request: LaunchRequest) async throws -> ProviderSessionRef
    func reconcile() async throws -> AdapterSnapshot
    func eventStream() async -> AsyncStream<AgentEvent>
    func recentTurns(
        for session: ProviderSessionRef,
        limit: Int
    ) async throws -> [VisibleTurn]
    func send(_ input: AgentInput, to session: ProviderSessionRef) async throws
    func resolve(
        _ request: ProviderRequestRef,
        decision: RequestDecision
    ) async throws
    func resolutionRoute(
        _ request: ProviderRequestRef,
        decision: RequestDecision
    ) async throws -> RequestResolutionRoute
    func jumpTarget(for session: ProviderSessionRef) async -> JumpTarget
}

public extension AgentAdapter {
    func resolutionRoute(
        _ request: ProviderRequestRef,
        decision: RequestDecision
    ) async throws -> RequestResolutionRoute {
        .provider
    }
}

public protocol HookEventIngestingAdapter: AgentAdapter {
    func ingest(_ envelope: ProviderHookEnvelope) async throws
}

public protocol ProviderConfigurableAdapter: AgentAdapter {
    func configure(_ action: ProviderConfigurationAction) async throws
}

public protocol EndpointConfigurableAdapter: AgentAdapter {
    func restoreEndpoint(_ endpoint: ProviderEndpoint) async throws
    func attachEndpoint(_ attachment: ProviderEndpointAttachment) async throws -> ProviderEndpoint
    func authenticateEndpoint(
        _ binding: ProviderEndpointCredentialBinding
    ) async throws -> ProviderEndpoint
    func detachEndpoint(id: String) async throws
}
