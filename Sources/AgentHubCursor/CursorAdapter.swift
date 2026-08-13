import CryptoKit
import Foundation
import AgentHubCore

public enum CursorAdapterError: Error, Equatable, Sendable {
    case sessionNotFound
    case unsupportedCapability
    case fingerprintMismatch
}

/// Normalizes local Cursor IDE Agent Chat hooks into AgentHub sessions,
/// nodes, and permission requests. There is no managed launch path.
public actor CursorAdapter: AgentAdapter, HookEventIngestingAdapter, HookPermissionProducingAdapter, ProviderConfigurableAdapter, QuotaForceRefreshing {
    public nonisolated var provider: Provider { .cursor }

    /// Verified Cursor.app bundle id on macOS (Cursor / Todesktop wrapper).
    public static let cursorBundleID = "com.todesktop.230313mzl4w4u92"

    private struct ObservedSession {
        var id: UUID
        var conversationID: String
        var title: String
        var cwd: String?
        var workspaceRoots: [String]
        var status: SessionStatus
        var lastActivityAt: Date
    }

    private struct ObservedRequest {
        var id: UUID
        var fingerprint: String
        var conversationID: String
        var generationID: String?
        var title: String
        var detail: String
        var createdAt: Date
    }

    private let accountID: String
    private let decoder = CursorHookDecoder()
    private let hookInstaller: CursorHookInstaller?
    private let quotaCollector: CursorQuotaCollector?
    private let makeSessionID: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    private var sessions: [String: ObservedSession] = [:]
    private var nodes: [String: AgentNode] = [:]
    private var requests: [String: ObservedRequest] = [:]
    private var components: [String: ProviderComponentStatus] = [:]
    private var publishedQuotaIDs: Set<String> = []
    private var continuations: [UUID: AsyncStream<AgentEvent>.Continuation] = [:]
    /// Last decision ingest's AgentHub request id, for the sync hook bridge.
    private(set) var lastPermissionRequestID: UUID?

    public init(
        accountID: String,
        hookInstaller: CursorHookInstaller? = nil,
        quotaCollector: CursorQuotaCollector? = nil,
        makeSessionID: @escaping @Sendable () -> UUID = { UUID() },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.accountID = accountID
        self.hookInstaller = hookInstaller
        self.quotaCollector = quotaCollector
        self.makeSessionID = makeSessionID
        self.now = now
    }

    public func takeLastPermissionRequestID() async -> UUID? {
        let id = lastPermissionRequestID
        lastPermissionRequestID = nil
        return id
    }

    public func capabilities() async -> [Capability: ReliabilityLevel] {
        [
            .discover: .l2,
            .status: .l2,
            .children: .l2,
            .recentTurns: .l3,
            .resolveRequest: .l2,
            .jump: .l3,
            .quota: .l3,
        ]
    }

    public func launch(_ request: LaunchRequest) async throws -> ProviderSessionRef {
        _ = request
        throw CursorAdapterError.unsupportedCapability
    }

    public func reconcile() async throws -> AdapterSnapshot {
        let quotas: [QuotaWindow]
        if let quotaCollector {
            quotas = await quotaCollector.currentWindows()
        } else {
            quotas = []
        }
        return AdapterSnapshot(
            sessions: sessions.values.map(session(from:)).sorted { $0.id.uuidString < $1.id.uuidString },
            nodes: Array(nodes.values),
            requests: requests.values.map(pendingRequest(from:)),
            quotas: quotas,
            endpoints: [],
            requestsAreAuthoritative: true
        )
    }

    public func eventStream() async -> AsyncStream<AgentEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    public func recentTurns(
        for session: ProviderSessionRef,
        limit: Int
    ) async throws -> [VisibleTurn] {
        _ = session
        _ = limit
        return []
    }

    public func send(_ input: AgentInput, to session: ProviderSessionRef) async throws {
        _ = input
        _ = session
        throw CursorAdapterError.unsupportedCapability
    }

    public func resolve(
        _ request: ProviderRequestRef,
        decision: RequestDecision
    ) async throws {
        guard let observed = requests.values.first(where: {
            $0.fingerprint == request.requestID || $0.id.uuidString == request.requestID
        }) else {
            throw CursorAdapterError.sessionNotFound
        }

        // Re-validate fingerprint identity for sync hooks.
        guard observed.fingerprint == request.requestID
            || observed.id.uuidString == request.requestID else {
            throw CursorAdapterError.fingerprintMismatch
        }

        requests.removeValue(forKey: observed.fingerprint)
        emit(.requestResolved(id: observed.id, outcome: String(describing: decision)))
        if var session = sessions[observed.conversationID] {
            session.status = .working
            session.lastActivityAt = now()
            sessions[observed.conversationID] = session
            emit(.sessionUpserted(self.session(from: session)))
        }
    }

    public func jumpTarget(for session: ProviderSessionRef) async -> JumpTarget {
        guard let observed = sessions[session.nativeID] else {
            return .unavailable("Cursor session is not currently observed")
        }
        let hint = observed.workspaceRoots.first ?? observed.cwd
        return .application(bundleID: Self.cursorBundleID, windowHint: hint)
    }

    public func ingest(_ envelope: ProviderHookEnvelope) async throws {
        guard envelope.provider == .cursor else {
            throw CursorAdapterError.unsupportedCapability
        }

        lastPermissionRequestID = nil
        let payload = try decoder.decode(envelope.rawJSON)
        touchSession(payload, at: envelope.observedAt)

        switch payload.event {
        case .sessionStart:
            setStatus(.idle, conversationID: payload.conversationID, at: envelope.observedAt)

        case .beforeSubmitPrompt, .afterAgentResponse, .afterAgentThought,
             .afterShellExecution, .afterMCPExecution, .preCompact:
            setStatus(.working, conversationID: payload.conversationID, at: envelope.observedAt)

        case .stop:
            setStatus(.idle, conversationID: payload.conversationID, at: envelope.observedAt)

        case .sessionEnd:
            setStatus(.completed, conversationID: payload.conversationID, at: envelope.observedAt)

        case .beforeShellExecution, .beforeMCPExecution:
            let requestID = await recordPermission(payload, at: envelope.observedAt)
            lastPermissionRequestID = requestID
            setStatus(
                .waitingPermission,
                conversationID: payload.conversationID,
                at: envelope.observedAt
            )

        case .subagentStart:
            if let subagentID = payload.subagentID {
                upsertNode(
                    nativeID: subagentID,
                    kind: payload.boundedPreview.isEmpty ? "subagent" : payload.boundedPreview,
                    status: .working,
                    conversationID: payload.conversationID,
                    at: envelope.observedAt
                )
            }

        case .subagentStop:
            if let subagentID = payload.subagentID {
                upsertNode(
                    nativeID: subagentID,
                    kind: "subagent",
                    status: .completed,
                    conversationID: payload.conversationID,
                    at: envelope.observedAt
                )
            }

        case .unknown:
            break
        }
    }

    @discardableResult
    public func configure(
        _ action: ProviderConfigurationAction
    ) async throws -> [ProviderComponentStatus] {
        switch action {
        case .installQuotaReporter, .uninstallQuotaReporter:
            throw CursorAdapterError.unsupportedCapability
        case .authorizeQuotaAccess:
            return try await authorizeQuota()
        case .revokeQuotaAccess:
            return try await revokeQuota()
        case .installHooks, .uninstallHooks, .refreshComponents:
            break
        }

        if action == .refreshComponents, let quotaCollector {
            _ = try? await quotaCollector.refresh()
            await syncQuotaWindows(from: quotaCollector)
        }

        var results: [ProviderComponentStatus] = []
        if let hookInstaller {
            switch action {
            case .installHooks:
                try hookInstaller.install()
            case .uninstallHooks:
                try hookInstaller.uninstall()
            case .refreshComponents, .installQuotaReporter, .uninstallQuotaReporter,
                 .authorizeQuotaAccess, .revokeQuotaAccess:
                break
            }
            let status = try hookInstaller.status()
            components[status.component] = status
            emit(.componentUpserted(status))
            results.append(status)
        } else {
            results.append(
                ProviderComponentStatus(
                    provider: .cursor,
                    component: "hooks",
                    available: false,
                    version: nil,
                    path: nil,
                    message: "The AgentHub Cursor hook helper is not installed yet.",
                    changedAt: now()
                )
            )
        }

        if let quotaCollector {
            let status = await quotaCollector.quotaComponentStatus()
            components[status.component] = status
            emit(.componentUpserted(status))
            results.append(status)
        }
        return results
    }

    private func authorizeQuota() async throws -> [ProviderComponentStatus] {
        guard let quotaCollector else {
            throw CursorAdapterError.unsupportedCapability
        }
        await quotaCollector.authorize()
        _ = try? await quotaCollector.refresh()
        await syncQuotaWindows(from: quotaCollector)
        let status = await quotaCollector.quotaComponentStatus()
        components[status.component] = status
        emit(.componentUpserted(status))
        return [status]
    }

    private func revokeQuota() async throws -> [ProviderComponentStatus] {
        guard let quotaCollector else {
            throw CursorAdapterError.unsupportedCapability
        }
        let removedIDs = publishedQuotaIDs
        await quotaCollector.revoke()
        for id in removedIDs {
            emit(.quotaRemoved(id: id))
        }
        publishedQuotaIDs.removeAll()
        let status = await quotaCollector.quotaComponentStatus()
        components[status.component] = status
        emit(.componentUpserted(status))
        return [status]
    }

    // MARK: - Internals

    private func touchSession(_ payload: CursorHookPayload, at date: Date) {
        if var existing = sessions[payload.conversationID] {
            existing.lastActivityAt = date
            if !payload.workspaceRoots.isEmpty {
                existing.workspaceRoots = payload.workspaceRoots
            }
            existing.cwd = payload.workspaceRoots.first ?? existing.cwd
            sessions[payload.conversationID] = existing
            return
        }

        sessions[payload.conversationID] = ObservedSession(
            id: makeSessionID(),
            conversationID: payload.conversationID,
            title: "Cursor \(payload.conversationID.prefix(8))",
            cwd: payload.workspaceRoots.first,
            workspaceRoots: payload.workspaceRoots,
            status: .starting,
            lastActivityAt: date
        )
    }

    private func setStatus(
        _ status: SessionStatus,
        conversationID: String,
        at date: Date
    ) {
        guard var observed = sessions[conversationID] else { return }
        observed.status = status
        observed.lastActivityAt = date
        sessions[conversationID] = observed
        emit(.sessionUpserted(session(from: observed)))
    }

    @discardableResult
    private func recordPermission(
        _ payload: CursorHookPayload,
        at date: Date
    ) async -> UUID {
        let fingerprint = fingerprint(
            conversationID: payload.conversationID,
            generationID: payload.generationID,
            event: payload.event.rawValue,
            preview: payload.boundedPreview
        )
        let id = makeSessionID()
        let title = payload.event == .beforeShellExecution
            ? "Shell permission"
            : "MCP permission"
        let observed = ObservedRequest(
            id: id,
            fingerprint: fingerprint,
            conversationID: payload.conversationID,
            generationID: payload.generationID,
            title: title,
            detail: payload.boundedPreview,
            createdAt: date
        )
        requests[fingerprint] = observed
        emit(.requestUpserted(pendingRequest(from: observed)))
        return id
    }

    private func upsertNode(
        nativeID: String,
        kind: String,
        status: SessionStatus,
        conversationID: String,
        at date: Date
    ) {
        guard let session = sessions[conversationID] else { return }
        let node = AgentNode(
            id: UUID(),
            sessionID: session.id,
            nativeID: nativeID,
            parentNativeID: nil,
            kind: kind,
            status: status,
            lastActivityAt: date
        )
        nodes[nativeID] = node
        emit(.nodeUpserted(node))
    }

    private func session(from observed: ObservedSession) -> AgentSession {
        AgentSession(
            id: observed.id,
            providerRef: ProviderSessionRef(
                provider: .cursor,
                accountID: accountID,
                nativeID: observed.conversationID
            ),
            title: observed.title,
            surface: "ide",
            ownership: .discovered,
            status: observed.status,
            rootID: observed.id,
            parentID: nil,
            cwd: observed.cwd,
            repository: nil,
            branch: nil,
            lastActivityAt: observed.lastActivityAt,
            capabilities: [
                .discover: .l2,
                .status: .l2,
                .children: .l2,
                .resolveRequest: .l2,
                .jump: .l3,
            ],
            preview: []
        )
    }

    private func pendingRequest(from observed: ObservedRequest) -> PendingRequest {
        PendingRequest(
            id: observed.id,
            provider: .cursor,
            providerRequestID: observed.fingerprint,
            sessionID: sessions[observed.conversationID]?.id ?? observed.id,
            threadID: observed.conversationID,
            turnID: observed.generationID,
            kind: .permission,
            title: observed.title,
            detail: observed.detail,
            allowedActions: ["Allow", "Deny"],
            state: .pending,
            reliability: .l2,
            createdAt: observed.createdAt
        )
    }

    private func fingerprint(
        conversationID: String,
        generationID: String?,
        event: String,
        preview: String
    ) -> String {
        let material = [
            conversationID,
            generationID ?? "",
            event,
            preview,
        ].joined(separator: "\u{1f}")
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func emit(_ event: AgentEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    /// Polls cursor.com on a long interval, so an explicit user refresh fetches
    /// now instead of waiting for the next tick.
    public func forceQuotaRefresh() async {
        guard let quotaCollector, await quotaCollector.isAuthorized else { return }
        _ = try? await quotaCollector.refresh()
        await syncQuotaWindows(from: quotaCollector)
    }

    private func syncQuotaWindows(from collector: CursorQuotaCollector) async {
        let windows = await collector.currentWindows()
        let nextIDs = Set(windows.map(\.id))
        for removed in publishedQuotaIDs.subtracting(nextIDs) {
            emit(.quotaRemoved(id: removed))
        }
        for window in windows {
            emit(.quotaUpserted(window))
        }
        publishedQuotaIDs = nextIDs
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}
