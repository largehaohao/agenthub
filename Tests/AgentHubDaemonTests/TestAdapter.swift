import Foundation
import AgentHubCore
import AgentHubTestSupport

actor TestAdapter: AgentAdapter {
    nonisolated let provider: Provider = .codex
    private(set) var sentInputs: [(AgentInput, ProviderSessionRef)] = []
    private(set) var resolvedRequests: [(ProviderRequestRef, RequestDecision)] = []
    var resolveError: Error?
    var sendError: Error?

    func capabilities() async -> [Capability: ReliabilityLevel] { [:] }
    func launch(_ request: LaunchRequest) async throws -> ProviderSessionRef { .fixture() }
    func reconcile() async throws -> AdapterSnapshot { .fixture() }
    func eventStream() async -> AsyncStream<AgentEvent> { AsyncStream { $0.finish() } }
    func recentTurns(for session: ProviderSessionRef, limit: Int) async throws -> [VisibleTurn] { [] }

    func send(_ input: AgentInput, to session: ProviderSessionRef) async throws {
        if let sendError { throw sendError }
        sentInputs.append((input, session))
    }

    func resolve(_ request: ProviderRequestRef, decision: RequestDecision) async throws {
        if let resolveError { throw resolveError }
        resolvedRequests.append((request, decision))
    }

    func jumpTarget(for session: ProviderSessionRef) async -> JumpTarget {
        .agentHubDetail(sessionNativeID: session.nativeID)
    }

    func setSendError(_ error: Error?) {
        sendError = error
    }
}
