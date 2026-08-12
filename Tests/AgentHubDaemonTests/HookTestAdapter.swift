import Foundation
import AgentHubCore
import AgentHubTestSupport

/// A Claude-shaped adapter that records hook ingestion, configuration actions,
/// and lets a test choose between provider and native resolution routes.
actor HookTestAdapter: HookEventIngestingAdapter, ProviderConfigurableAdapter {
    nonisolated let provider: Provider = .claude

    private var hooks: [ProviderHookEnvelope] = []
    private var actions: [ProviderConfigurationAction] = []
    private var route: RequestResolutionRoute = .provider
    private(set) var resolvedRequests: [(ProviderRequestRef, RequestDecision)] = []
    var snapshotToReturn: AdapterSnapshot = .fixture()

    func ingestedHooks() -> [ProviderHookEnvelope] { hooks }
    func configureActions() -> [ProviderConfigurationAction] { actions }

    func setResolutionRoute(_ value: RequestResolutionRoute) { route = value }

    func ingest(_ envelope: ProviderHookEnvelope) async throws {
        hooks.append(envelope)
    }

    var componentsToReturn: [ProviderComponentStatus] = []

    func setComponents(_ value: [ProviderComponentStatus]) { componentsToReturn = value }

    func configure(
        _ action: ProviderConfigurationAction
    ) async throws -> [ProviderComponentStatus] {
        actions.append(action)
        return componentsToReturn
    }

    func capabilities() async -> [Capability: ReliabilityLevel] { [:] }

    func launch(_ request: LaunchRequest) async throws -> ProviderSessionRef {
        snapshotToReturn.sessions.first?.providerRef ?? .fixture()
    }

    func reconcile() async throws -> AdapterSnapshot { snapshotToReturn }

    func eventStream() async -> AsyncStream<AgentEvent> { AsyncStream { $0.finish() } }

    func recentTurns(for session: ProviderSessionRef, limit: Int) async throws -> [VisibleTurn] {
        []
    }

    func send(_ input: AgentInput, to session: ProviderSessionRef) async throws {}

    func resolve(_ request: ProviderRequestRef, decision: RequestDecision) async throws {
        resolvedRequests.append((request, decision))
    }

    func resolutionRoute(
        _ request: ProviderRequestRef,
        decision: RequestDecision
    ) async throws -> RequestResolutionRoute {
        route
    }

    func jumpTarget(for session: ProviderSessionRef) async -> JumpTarget {
        .agentHubDetail(sessionNativeID: session.nativeID)
    }
}
