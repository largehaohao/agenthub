import Foundation
import AgentHubCore
import AgentHubPersistence

public enum RequestServiceError: Error, Equatable, Sendable {
    case notFound
    case notPending
    case unsupportedProvider
}

/// What resolving a request produced.
public enum RequestResolutionOutcome: Equatable, Sendable {
    /// The provider acknowledged the decision and local state converged.
    case resolved
    /// The app must perform a verified native UI action before the request
    /// advances; it stays pending until the app reports back.
    case native(NativeInteractionPlan)
}

public actor RequestService {
    private let store: AgentHubStore
    private let adapters: [Provider: any AgentAdapter]
    /// Native plans awaiting confirmation that the app acted on the real UI.
    private var pendingNativePlans: [UUID: NativeInteractionPlan] = [:]

    public init(
        store: AgentHubStore,
        adapters: [Provider: any AgentAdapter]
    ) {
        self.store = store
        self.adapters = adapters
    }

    @discardableResult
    public func resolve(
        id: UUID,
        decision: RequestDecision
    ) async throws -> RequestResolutionOutcome {
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

        let reference = ProviderRequestRef(
            provider: request.provider,
            requestID: request.providerRequestID,
            threadID: request.threadID,
            turnID: request.turnID,
            itemID: request.itemID
        )

        // A native route hands the action to the app. Persisted state must not
        // move yet: only the app can confirm the real UI was driven.
        if case .native(let plan) = try await adapter.resolutionRoute(reference, decision: decision) {
            pendingNativePlans[id] = plan
            return .native(plan)
        }

        try await store.apply(.requestResolutionStarted(id: id))
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
        return .resolved
    }

    /// Advances a native request only when the app reports the exact request
    /// and plan it was handed, so a stale or forged report cannot move state.
    public func nativeInteractionStarted(requestID: UUID, planID: UUID) async throws {
        guard let plan = pendingNativePlans[requestID], plan.id == planID else {
            throw RequestServiceError.notFound
        }
        pendingNativePlans.removeValue(forKey: requestID)
        try await store.apply(.requestResolutionStarted(id: requestID))
        try await store.appendAudit(AuditEvent(
            action: "request.native-interaction",
            provider: plan.provider.rawValue,
            sessionID: nil
        ))
    }

    /// Waits for a pending request to be resolved from AgentHub, or returns
    /// `.ask` when the timeout elapses / the request is missing. Never returns
    /// `.allow` by default. Task 4 replaces this stub with a continuation map.
    public func awaitHookPermission(
        requestID: UUID,
        timeoutMilliseconds: Int
    ) async -> HookPermissionDecision {
        _ = requestID
        let nanoseconds = UInt64(max(0, timeoutMilliseconds)) * 1_000_000
        try? await Task.sleep(nanoseconds: min(nanoseconds, 50_000_000))
        return .ask
    }
}
