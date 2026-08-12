import CryptoKit
import Foundation
import AgentHubCore

public enum ClaudeAdapterError: Error, Equatable, Sendable {
    case sessionNotFound
    case unsupportedCapability
    case sessionBusy
    case launchTimedOut
}

/// Normalizes Claude CLI and Desktop activity into AgentHub's shared session,
/// node, and request abstractions.
///
/// Raw hook payloads live only for the duration of `ingest`. Everything retained
/// afterwards is normalized and display-safe, so tool inputs, prompts, and
/// transcripts never enter AgentHub storage.
public actor ClaudeAdapter: AgentAdapter, HookEventIngestingAdapter, ProviderConfigurableAdapter {
    public nonisolated var provider: Provider { .claude }

    /// Identity of one observed Claude session: the same native session ID on a
    /// different surface is a genuinely different session.
    private struct SessionKey: Hashable {
        let nativeID: String
        let surface: ClaudeSurface
    }

    private struct ObservedSession {
        var id: UUID
        var key: SessionKey
        var title: String
        var cwd: String
        var transcriptPath: String
        var status: SessionStatus
        var lastActivityAt: Date
        var claudeSessionID: UUID?
    }

    private struct ObservedRequest {
        var id: UUID
        var fingerprint: String
        var sessionKey: SessionKey
        var toolName: String
        var kind: RequestKind
        var title: String
        var detail: String
        var allowedActions: [String]
        var createdAt: Date
    }

    private let accountID: String
    private let classifier: ClaudeProcessClassifier
    private let decoder = ClaudeHookDecoder()
    private let transcripts: (any ClaudeTranscriptReading)?
    private let now: @Sendable () -> Date

    private var sessions: [SessionKey: ObservedSession] = [:]
    private var nodes: [String: AgentNode] = [:]
    private var requests: [String: ObservedRequest] = [:]
    private var managedSessionIDs: Set<UUID> = []
    private var managedRuntimes: [SessionKey: ClaudeManagedRuntime] = [:]
    private var continuations: [UUID: AsyncStream<AgentEvent>.Continuation] = [:]

    public init(
        accountID: String,
        classifier: ClaudeProcessClassifier = ClaudeProcessClassifier(),
        transcripts: (any ClaudeTranscriptReading)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.accountID = accountID
        self.classifier = classifier
        self.transcripts = transcripts
        self.now = now
    }

    // MARK: - Hook ingestion

    public func ingest(_ envelope: ProviderHookEnvelope) async throws {
        guard envelope.provider == .claude else {
            throw ClaudeAdapterError.unsupportedCapability
        }

        let event = try decoder.decode(envelope.rawJSON)
        guard let common = event.common else { return }

        let claudeSessionID = UUID(uuidString: common.sessionID)
        let surface = classifier.surface(
            for: envelope.ancestors,
            managedSessionIDs: managedSessionIDs,
            claudeSessionID: claudeSessionID
        )
        let key = SessionKey(nativeID: common.sessionID, surface: surface)
        touchSession(key, common: common, claudeSessionID: claudeSessionID, at: envelope.observedAt)

        switch event {
        case .sessionStart:
            setStatus(.idle, for: key, at: envelope.observedAt)

        case .userPromptSubmit:
            setStatus(.working, for: key, at: envelope.observedAt)

        case .stop:
            setStatus(.idle, for: key, at: envelope.observedAt)

        case .stopFailure:
            setStatus(.error, for: key, at: envelope.observedAt)

        case .sessionEnd:
            setStatus(.completed, for: key, at: envelope.observedAt)

        case .permissionRequest(let value):
            record(
                request: value.toolName,
                kind: .permission,
                title: "Permission requested",
                detail: "Claude is requesting permission to run \(value.toolName).",
                actions: value.options.isEmpty ? ["Yes", "No"] : value.options,
                key: key,
                at: envelope.observedAt
            )
            setStatus(.waitingPermission, for: key, at: envelope.observedAt)

        case .preToolUse(let value) where value.toolName == "AskUserQuestion":
            guard let question = value.questions.first else { break }
            record(
                request: value.toolName,
                kind: .choice,
                title: question.prompt,
                detail: question.header ?? "Claude is asking a question.",
                actions: question.options.map(\.label),
                key: key,
                at: envelope.observedAt
            )
            setStatus(.waitingInput, for: key, at: envelope.observedAt)

        case .postToolUse(let value):
            closeRequests(for: key, toolName: value.toolName, at: envelope.observedAt)

        case .permissionDenied(let value):
            closeRequests(for: key, toolName: value.toolName, at: envelope.observedAt)

        case .subagentStart(let value):
            upsertNode(
                nativeID: value.agentID,
                kind: value.agentType ?? "subagent",
                status: .working,
                key: key,
                at: envelope.observedAt
            )

        case .subagentStop(let value):
            upsertNode(
                nativeID: value.agentID,
                kind: value.agentType ?? "subagent",
                status: .completed,
                key: key,
                at: envelope.observedAt
            )

        case .taskCreated(let value):
            upsertNode(
                nativeID: value.taskID,
                kind: "task",
                status: .working,
                key: key,
                at: envelope.observedAt
            )

        case .taskCompleted(let value):
            upsertNode(
                nativeID: value.taskID,
                kind: "task",
                status: .completed,
                key: key,
                at: envelope.observedAt
            )

        case .preToolUse, .notification, .teammateIdle, .unknown:
            break
        }
    }

    public func configure(_ action: ProviderConfigurationAction) async throws {
        // Hook installation is owned by ClaudeHookInstaller and driven by the
        // daemon; the adapter exposes the action without side effects here.
    }

    // MARK: - AgentAdapter

    public func capabilities() async -> [Capability: ReliabilityLevel] {
        [
            .discover: .l2,
            .status: .l2,
            .children: .l2,
            .recentTurns: .l2,
            .resolveRequest: .l3,
            .jump: .l3,
        ]
    }

    public func launch(_ request: LaunchRequest) async throws -> ProviderSessionRef {
        // Managed launch arrives with Task 10's runtime wiring.
        throw ClaudeAdapterError.unsupportedCapability
    }

    public func reconcile() async throws -> AdapterSnapshot {
        AdapterSnapshot(
            sessions: sessions.values.map(session(from:)),
            nodes: Array(nodes.values),
            requests: requests.values.map(pendingRequest(from:)),
            quotas: [],
            endpoints: [],
            requestsAreAuthoritative: true
        )
    }

    public func eventStream() async -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let id = UUID()
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
        guard let observed = observedSession(for: session) else {
            throw ClaudeAdapterError.sessionNotFound
        }
        guard let transcripts else { return [] }
        return try transcripts.recentTurns(path: observed.transcriptPath, limit: limit)
    }

    public func send(_ input: AgentInput, to session: ProviderSessionRef) async throws {
        guard let observed = observedSession(for: session) else {
            throw ClaudeAdapterError.sessionNotFound
        }
        // Only a verified AgentHub-managed tmux runtime can receive direct
        // input; external CLI and Desktop remain clipboard-and-jump.
        guard observed.key.surface == .managedCLI else {
            throw ClaudeAdapterError.unsupportedCapability
        }
        throw ClaudeAdapterError.unsupportedCapability
    }

    public func resolve(
        _ request: ProviderRequestRef,
        decision: RequestDecision
    ) async throws {
        guard requests[request.requestID] != nil else {
            throw ClaudeAdapterError.sessionNotFound
        }
        throw ClaudeAdapterError.unsupportedCapability
    }

    public func resolutionRoute(
        _ request: ProviderRequestRef,
        decision: RequestDecision
    ) async throws -> RequestResolutionRoute {
        guard let observed = requests[request.requestID],
              let session = sessions[observed.sessionKey] else {
            throw ClaudeAdapterError.sessionNotFound
        }

        switch observed.sessionKey.surface {
        case .desktop:
            // The plan carries only identity and a fingerprint; the app
            // revalidates the live UI before acting on it.
            return .native(
                NativeInteractionPlan(
                    id: UUID(),
                    provider: .claude,
                    requestID: observed.id,
                    bundleID: "com.anthropic.claudefordesktop",
                    windowHint: session.title,
                    sessionNativeID: observed.sessionKey.nativeID,
                    promptFingerprint: observed.fingerprint,
                    operation: operation(for: decision, options: observed.allowedActions)
                )
            )

        case .managedCLI, .externalCLI:
            return .provider
        }
    }

    public func jumpTarget(for session: ProviderSessionRef) async -> JumpTarget {
        guard let observed = observedSession(for: session) else {
            return .unavailable("This Claude session is no longer being observed.")
        }

        switch observed.key.surface {
        case .managedCLI:
            guard let runtime = managedRuntimes[observed.key] else {
                return .unavailable("The managed terminal for this session is unavailable.")
            }
            return .application(
                bundleID: "com.googlecode.iterm2",
                windowHint: runtime.sessionName
            )

        case .desktop:
            return .application(
                bundleID: "com.anthropic.claudefordesktop",
                windowHint: observed.title
            )

        case .externalCLI:
            // A discovered terminal cannot be matched to an exact window, so
            // AgentHub degrades rather than focusing an arbitrary one.
            return .unavailable(
                "This Claude session runs in a terminal AgentHub cannot target exactly."
            )
        }
    }

    // MARK: - State maintenance

    private func touchSession(
        _ key: SessionKey,
        common: ClaudeHookCommon,
        claudeSessionID: UUID?,
        at date: Date
    ) {
        if var existing = sessions[key] {
            existing.lastActivityAt = date
            existing.transcriptPath = common.transcriptPath
            existing.cwd = common.cwd
            sessions[key] = existing
            return
        }

        sessions[key] = ObservedSession(
            id: deterministicID("session", key.nativeID, key.surface.rawValue),
            key: key,
            title: URL(fileURLWithPath: common.cwd).lastPathComponent,
            cwd: common.cwd,
            transcriptPath: common.transcriptPath,
            status: .idle,
            lastActivityAt: date,
            claudeSessionID: claudeSessionID
        )
    }

    private func setStatus(_ status: SessionStatus, for key: SessionKey, at date: Date) {
        guard var session = sessions[key] else { return }
        session.status = status
        session.lastActivityAt = date
        sessions[key] = session
        emit(.sessionUpserted(self.session(from: session)))
    }

    private func upsertNode(
        nativeID: String,
        kind: String,
        status: SessionStatus,
        key: SessionKey,
        at date: Date
    ) {
        guard let session = sessions[key] else { return }
        let node = AgentNode(
            id: deterministicID("node", key.nativeID, nativeID),
            sessionID: session.id,
            nativeID: nativeID,
            // Claude does not report subagent parentage; ancestry is never
            // inferred from titles or timing.
            parentNativeID: nil,
            kind: kind,
            status: status,
            lastActivityAt: date
        )
        nodes[nativeID] = node
        emit(.nodeUpserted(node))
    }

    private func record(
        request toolName: String,
        kind: RequestKind,
        title: String,
        detail: String,
        actions: [String],
        key: SessionKey,
        at date: Date
    ) {
        let fingerprint = self.fingerprint(key: key, toolName: toolName, actions: actions)
        guard requests[fingerprint] == nil else { return }

        let observed = ObservedRequest(
            id: deterministicID("request", key.nativeID, fingerprint),
            fingerprint: fingerprint,
            sessionKey: key,
            toolName: toolName,
            kind: kind,
            title: title,
            detail: detail,
            allowedActions: actions,
            createdAt: date
        )
        requests[fingerprint] = observed
        emit(.requestUpserted(pendingRequest(from: observed)))
    }

    private func closeRequests(for key: SessionKey, toolName: String, at date: Date) {
        for (fingerprint, observed) in requests
        where observed.sessionKey == key && observed.toolName == toolName {
            requests.removeValue(forKey: fingerprint)
            emit(.requestResolved(id: observed.id, outcome: "closed natively"))
        }
        setStatus(.working, for: key, at: date)
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func emit(_ event: AgentEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    // MARK: - Projection

    private func session(from observed: ObservedSession) -> AgentSession {
        var capabilities: [Capability: ReliabilityLevel] = [
            .discover: .l2,
            .status: .l2,
            .children: .l2,
            .recentTurns: .l2,
            .resolveRequest: .l3,
            .jump: .l3,
        ]
        if observed.key.surface == .managedCLI {
            capabilities[.sendInput] = .l2
            capabilities[.jump] = .l2
        }

        return AgentSession(
            id: observed.id,
            providerRef: ProviderSessionRef(
                provider: .claude,
                accountID: accountID,
                nativeID: observed.key.nativeID
            ),
            title: observed.title,
            surface: observed.key.surface.rawValue,
            ownership: observed.key.surface == .managedCLI ? .managed : .discovered,
            status: observed.status,
            rootID: observed.id,
            cwd: observed.cwd,
            lastActivityAt: observed.lastActivityAt,
            capabilities: capabilities,
            preview: []
        )
    }

    private func pendingRequest(from observed: ObservedRequest) -> PendingRequest {
        PendingRequest(
            id: observed.id,
            provider: .claude,
            providerRequestID: observed.fingerprint,
            sessionID: sessions[observed.sessionKey]?.id ?? observed.id,
            threadID: observed.sessionKey.nativeID,
            kind: observed.kind,
            title: observed.title,
            detail: observed.detail,
            allowedActions: observed.allowedActions,
            state: .pending,
            reliability: .l3,
            createdAt: observed.createdAt
        )
    }

    private func operation(
        for decision: RequestDecision,
        options: [String]
    ) -> NativeInteractionOperation {
        switch decision {
        case .accept, .acceptForSession:
            .choose(label: options.first ?? "Yes")
        case .decline, .cancel:
            .choose(label: options.last ?? "No")
        case .choices(let labels):
            .choose(label: labels.first ?? "")
        case .answers(let grouped):
            .choose(label: grouped.first?.first ?? "")
        case .text(let value):
            .enter(text: value)
        }
    }

    private func observedSession(for reference: ProviderSessionRef) -> ObservedSession? {
        sessions.values.first { $0.key.nativeID == reference.nativeID }
    }

    /// Stable within a session so a repeated hook for the same pending prompt
    /// does not create a second request row.
    private func fingerprint(key: SessionKey, toolName: String, actions: [String]) -> String {
        let material = "\(key.nativeID)|\(key.surface.rawValue)|\(toolName)|\(actions.joined(separator: "|"))"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func deterministicID(_ namespace: String, _ first: String, _ second: String) -> UUID {
        let digest = SHA256.hash(data: Data("\(namespace)|\(accountID)|\(first)|\(second)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

private extension ClaudeHookEvent {
    /// Common fields for every supported event; `.unknown` carries none.
    var common: ClaudeHookCommon? {
        switch self {
        case .sessionStart(let value): value.common
        case .sessionEnd(let value): value.common
        case .userPromptSubmit(let value): value.common
        case .stop(let value): value.common
        case .stopFailure(let value): value.common
        case .preToolUse(let value): value.common
        case .postToolUse(let value): value.common
        case .permissionRequest(let value): value.common
        case .permissionDenied(let value): value.common
        case .notification(let value): value.common
        case .subagentStart(let value): value.common
        case .subagentStop(let value): value.common
        case .taskCreated(let value): value.common
        case .taskCompleted(let value): value.common
        case .teammateIdle(let value): value.common
        case .unknown: nil
        }
    }
}
