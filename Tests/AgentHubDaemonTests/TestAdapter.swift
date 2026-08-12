import Foundation
import AgentHubCore
import AgentHubTestSupport

actor TestAdapter: EndpointConfigurableAdapter {
    nonisolated let provider: Provider = .codex
    private(set) var sentInputs: [(AgentInput, ProviderSessionRef)] = []
    private(set) var resolvedRequests: [(ProviderRequestRef, RequestDecision)] = []
    var resolveError: Error?
    var sendError: Error?
    private(set) var launchRequests: [LaunchRequest] = []
    var launchDelay: Duration?
    var snapshotToReturn: AdapterSnapshot = .fixture()
    private(set) var restoredEndpoints: [ProviderEndpoint] = []
    private(set) var restoredEndpointCountAtReconcile = 0
    private(set) var detachedEndpointIDs: [String] = []

    func capabilities() async -> [Capability: ReliabilityLevel] { [:] }
    func launch(_ request: LaunchRequest) async throws -> ProviderSessionRef {
        launchRequests.append(request)
        if let launchDelay {
            try await Task.sleep(for: launchDelay)
        }
        return snapshotToReturn.sessions.first?.providerRef ?? .fixture()
    }
    private(set) var reconcileCount = 0

    func reconcile() async throws -> AdapterSnapshot {
        restoredEndpointCountAtReconcile = restoredEndpoints.count
        reconcileCount += 1
        return snapshotToReturn
    }
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

    func restoreEndpoint(_ endpoint: ProviderEndpoint) async throws {
        restoredEndpoints.append(endpoint)
    }

    func attachEndpoint(_ attachment: ProviderEndpointAttachment) async throws -> ProviderEndpoint {
        let endpoint = ProviderEndpoint(
            id: "attached-\(attachment.provider.rawValue)",
            provider: attachment.provider,
            origin: .manual,
            baseURL: attachment.baseURL,
            credentialReference: attachment.credentialReference,
            connected: true,
            lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        restoredEndpoints.append(endpoint)
        return endpoint
    }

    func authenticateEndpoint(
        _ binding: ProviderEndpointCredentialBinding
    ) async throws -> ProviderEndpoint {
        let endpoint = ProviderEndpoint(
            id: binding.endpointID,
            provider: binding.provider,
            origin: .desktop,
            baseURL: "http://127.0.0.1:41789",
            credentialReference: binding.credentialReference,
            connected: true,
            lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        restoredEndpoints.append(endpoint)
        return endpoint
    }

    func detachEndpoint(id: String) async throws {
        detachedEndpointIDs.append(id)
    }

    func setSendError(_ error: Error?) {
        sendError = error
    }

    func setSnapshot(_ snapshot: AdapterSnapshot) {
        snapshotToReturn = snapshot
    }

    func setLaunchDelay(_ delay: Duration?) {
        launchDelay = delay
    }
}
