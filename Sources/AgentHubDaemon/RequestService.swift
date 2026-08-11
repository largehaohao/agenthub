import Foundation
import AgentHubCore
import AgentHubPersistence

public enum RequestServiceError: Error, Equatable, Sendable {
    case notFound
    case notPending
    case unsupportedProvider
}

public actor RequestService {
    private let store: AgentHubStore
    private let adapters: [Provider: any AgentAdapter]

    public init(
        store: AgentHubStore,
        adapters: [Provider: any AgentAdapter]
    ) {
        self.store = store
        self.adapters = adapters
    }

    public func resolve(id: UUID, decision: RequestDecision) async throws {
        let snapshot = try await store.snapshot()
        guard let request = snapshot.requests[id] else {
            throw RequestServiceError.notFound
        }
        guard request.state == .pending else {
            throw RequestServiceError.notPending
        }
        guard let adapter = adapters[request.provider] else {
            throw RequestServiceError.unsupportedProvider
        }

        try await store.apply(.requestResolutionStarted(id: id))
        let reference = ProviderRequestRef(
            provider: request.provider,
            requestID: request.providerRequestID,
            threadID: request.threadID,
            turnID: request.turnID,
            itemID: request.itemID
        )
        do {
            try await adapter.resolve(reference, decision: decision)
        } catch AdapterOperationError.requestAlreadyResolved {
            // The provider is authoritative; converge local state below.
        }
        try await store.apply(.requestResolved(id: id, outcome: String(describing: decision)))
        try await store.appendAudit(AuditEvent(
            action: "request.resolved",
            provider: request.provider.rawValue,
            sessionID: request.sessionID
        ))
    }
}
