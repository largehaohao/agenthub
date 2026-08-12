import Foundation

public struct AgentHubState: Equatable, Codable, Sendable {
    public var sessions: [UUID: AgentSession]
    public var nodes: [UUID: AgentNode]
    public var requests: [UUID: PendingRequest]
    public var envelopes: [UUID: MessageEnvelope]
    public var quotas: [String: QuotaWindow]
    public var adapterHealth: [Provider: AdapterHealth]
    public var endpoints: [String: ProviderEndpoint]
    public var components: [String: ProviderComponentStatus]

    public init(
        sessions: [UUID: AgentSession] = [:],
        nodes: [UUID: AgentNode] = [:],
        requests: [UUID: PendingRequest] = [:],
        envelopes: [UUID: MessageEnvelope] = [:],
        quotas: [String: QuotaWindow] = [:],
        adapterHealth: [Provider: AdapterHealth] = [:],
        endpoints: [String: ProviderEndpoint] = [:],
        components: [String: ProviderComponentStatus] = [:]
    ) {
        self.sessions = sessions
        self.nodes = nodes
        self.requests = requests
        self.envelopes = envelopes
        self.quotas = quotas
        self.adapterHealth = adapterHealth
        self.endpoints = endpoints
        self.components = components
    }

    public static let empty = AgentHubState()
}

public enum StateReducer {
    public static func reduce(state: inout AgentHubState, event: AgentEvent) {
        switch event {
        case .sessionUpserted(var session):
            session.preview = Array(session.preview.suffix(3))
            let duplicateIDs = state.sessions.values
                .filter { $0.providerRef == session.providerRef && $0.id != session.id }
                .map(\.id)
            for id in duplicateIDs {
                state.sessions.removeValue(forKey: id)
            }
            state.sessions[session.id] = session

        case .nodeUpserted(let node):
            state.nodes[node.id] = node

        case .requestUpserted(let request):
            guard let existing = state.requests[request.id] else {
                state.requests[request.id] = request
                return
            }
            guard !isTerminal(existing.state) else { return }
            guard requestRank(request.state) >= requestRank(existing.state) else {
                return
            }
            state.requests[request.id] = request

        case .requestResolutionStarted(let id):
            guard var request = state.requests[id], request.state == .pending else {
                return
            }
            request.state = .resolving
            state.requests[id] = request

        case .requestResolved(let id, _):
            guard var request = state.requests[id], request.state != .expired else {
                return
            }
            request.state = .resolved
            state.requests[id] = request

        case .requestExpired(let id):
            guard var request = state.requests[id], !isTerminal(request.state) else {
                return
            }
            request.state = .expired
            state.requests[id] = request

        case .envelopeUpserted(let envelope):
            state.envelopes[envelope.id] = envelope

        case .quotaUpserted(let quota):
            state.quotas[quota.id] = quota

        case .adapterHealth(let provider, let health):
            state.adapterHealth[provider] = health
            guard !health.connected else { return }
            for (id, var session) in state.sessions
                where session.providerRef.provider == provider
            {
                session.status = .disconnected
                state.sessions[id] = session
            }

        case .endpointUpserted(let endpoint):
            state.endpoints[endpoint.id] = endpoint

        case .endpointRemoved(let id):
            state.endpoints.removeValue(forKey: id)

        case .componentUpserted(let component):
            state.components[component.id] = component
        }
    }

    private static func requestRank(_ state: RequestState) -> Int {
        switch state {
        case .pending: 0
        case .resolving: 1
        case .resolved, .expired: 2
        }
    }

    private static func isTerminal(_ state: RequestState) -> Bool {
        state == .resolved || state == .expired
    }
}
