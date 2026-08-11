import Foundation
import AgentHubCore
import AgentHubPersistence

public enum HandoffServiceError: Error, Equatable, Sendable {
    case expired
    case invalidExpiry
    case sessionNotFound
    case unsupportedProvider
    case targetMismatch
    case notRetryable
}

public actor HandoffService {
    private let store: AgentHubStore
    private let adapters: [Provider: any AgentAdapter]
    private let now: @Sendable () -> Date

    public init(
        store: AgentHubStore,
        adapters: [Provider: any AgentAdapter],
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.adapters = adapters
        self.now = now
    }

    public func submit(
        _ envelope: MessageEnvelope,
        target: AgentSession,
        pendingRequests: [PendingRequest]
    ) async throws {
        guard envelope.targetSessionID == target.id else {
            throw HandoffServiceError.targetMismatch
        }
        guard envelope.expiresAt.timeIntervalSince(envelope.createdAt) <= 5 * 60 else {
            throw HandoffServiceError.invalidExpiry
        }
        guard now() <= envelope.expiresAt else {
            throw HandoffServiceError.expired
        }
        var normalized = envelope
        normalized.turns = Array(envelope.turns.suffix(20))

        switch HandoffRouter.eligibility(
            target: target,
            pendingRequests: pendingRequests
        ) {
        case .deliverNow:
            try await deliver(normalized, target: target)
        case .queue, .blockedByRequest:
            var queued = normalized
            queued.state = .queued
            queued.failure = nil
            try await store.apply(.envelopeUpserted(queued))
        case .manualOnly(let reason):
            var manual = normalized
            manual.state = .manual
            manual.failure = reason
            try await store.apply(.envelopeUpserted(manual))
        }
    }

    public func sessionBecameIdle(
        _ session: AgentSession,
        pendingRequests: [PendingRequest]
    ) async {
        guard session.status == .idle else { return }
        guard let snapshot = try? await store.snapshot() else { return }
        let queued = snapshot.envelopes.values.filter {
            $0.targetSessionID == session.id && $0.state == .queued
        }
        for envelope in queued {
            try? await submit(
                envelope,
                target: session,
                pendingRequests: pendingRequests
            )
        }
    }

    public func retry(id: UUID) async throws {
        let snapshot = try await store.snapshot()
        guard let envelope = snapshot.envelopes[id],
              let target = snapshot.sessions[envelope.targetSessionID] else {
            throw HandoffServiceError.sessionNotFound
        }
        guard envelope.state == .failed else {
            throw HandoffServiceError.notRetryable
        }
        let requests = snapshot.requests.values.filter {
            $0.sessionID == target.id
        }
        try await submit(envelope, target: target, pendingRequests: requests)
    }

    private func deliver(
        _ envelope: MessageEnvelope,
        target: AgentSession
    ) async throws {
        let snapshot = try await store.snapshot()
        guard let source = snapshot.sessions[envelope.sourceSessionID] else {
            throw HandoffServiceError.sessionNotFound
        }
        guard let adapter = adapters[target.providerRef.provider] else {
            throw HandoffServiceError.unsupportedProvider
        }

        var delivering = envelope
        delivering.turns = Array(envelope.turns.suffix(20))
        delivering.state = .delivering
        delivering.failure = nil
        try await store.apply(.envelopeUpserted(delivering))
        do {
            try await adapter.send(
                AgentInput(
                    text: HandoffRouter.render(delivering, source: source),
                    provenance: "AgentHub handoff \(envelope.id.uuidString)"
                ),
                to: target.providerRef
            )
            delivering.state = .delivered
            try await store.apply(.envelopeUpserted(delivering))
            try await store.appendAudit(AuditEvent(
                action: "handoff.delivered",
                provider: target.providerRef.provider.rawValue,
                sessionID: target.id
            ))
        } catch {
            delivering.state = .failed
            delivering.failure = "Delivery failed"
            try? await store.apply(.envelopeUpserted(delivering))
            throw error
        }
    }
}
