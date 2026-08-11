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
    func jumpTarget(for session: ProviderSessionRef) async -> JumpTarget
}
