import Combine
import Foundation
import AgentHubCore
import AgentHubIPC
import AgentHubSecurity

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var state: AgentHubState = .empty
    @Published var selectedSessionID: UUID?
    @Published private(set) var connection: ConnectionState = .connecting
    @Published private(set) var message: String?

    private let client: any DaemonClientProtocol
    private let jumpOpener: any JumpOpening
    private let credentials: any CredentialStoring
    private let nativeExecutor: any NativeInteractionExecuting
    private let retryDelay: @Sendable (Int) -> Duration
    private var resolvingRequestIDs: Set<UUID> = []
    private var eventTask: Task<Void, Never>?

    init(
        client: any DaemonClientProtocol,
        jumpOpener: any JumpOpening = WorkspaceJumpOpener(),
        credentials: any CredentialStoring = KeychainCredentialStore(),
        nativeExecutor: any NativeInteractionExecuting = ClaudeNativeInteractionExecutor(
            surface: AXClaudeAccessibilitySurface()
        ),
        retryDelay: @escaping @Sendable (Int) -> Duration = { attempt in
            let delays = ReconnectSchedule.delays
            return .seconds(delays[min(attempt, delays.count - 1)])
        }
    ) {
        self.client = client
        self.jumpOpener = jumpOpener
        self.credentials = credentials
        self.nativeExecutor = nativeExecutor
        self.retryDelay = retryDelay
    }

    func connect() async {
        var attempt = 0
        while !Task.isCancelled {
            connection = .connecting
            do {
                try await client.connect()
                connection = .connected
                try await refresh()
                let events = await client.events()
                eventTask?.cancel()
                eventTask = Task { [weak self] in
                    for await event in events {
                        guard !Task.isCancelled else { return }
                        switch event {
                        case .stateChanged, .adapterHealth:
                            try? await self?.refresh()
                        }
                    }
                }
                return
            } catch {
                connection = .disconnected("AgentHub daemon unavailable")
                do {
                    try await Task.sleep(for: retryDelay(attempt))
                } catch {
                    return
                }
                attempt += 1
            }
        }
    }

    func launch(
        provider: Provider,
        cwd: String,
        prompt: String,
        agent: String?,
        model: LaunchModelSelection?
    ) async {
        guard !cwd.isEmpty, !prompt.isEmpty else { return }
        let request = LaunchRequest(
            clientRequestID: UUID().uuidString,
            cwd: cwd,
            prompt: prompt,
            agent: nonempty(agent),
            model: model
        )
        await perform(
            .launch(provider, request),
            failure: "Unable to launch \(provider.displayName)"
        )
    }

    func attachOpenCode(url: String, password: String) async {
        let reference = nonempty(password).map { _ in "opencode:\(UUID().uuidString)" }
        do {
            if let reference {
                try credentials.save(password, reference: reference)
            }
            let reply = try await client.send(.attachEndpoint(.init(
                provider: .openCode,
                baseURL: url,
                credentialReference: reference
            )))
            guard case .endpoint = reply else {
                try? rollback(reference)
                message = reply.failureMessage ?? "Unable to attach OpenCode endpoint"
                return
            }
            message = nil
            try? await refresh()
        } catch {
            try? rollback(reference)
            message = "Unable to attach OpenCode endpoint"
        }
    }

    func authenticateOpenCode(endpointID: String, password: String) async {
        guard let password = nonempty(password) else { return }
        let reference = "opencode:\(UUID().uuidString)"
        do {
            try credentials.save(password, reference: reference)
            let reply = try await client.send(.authenticateEndpoint(.init(
                provider: .openCode,
                endpointID: endpointID,
                credentialReference: reference
            )))
            guard case .endpoint = reply else {
                try? rollback(reference)
                message = reply.failureMessage ?? "Unable to authenticate OpenCode endpoint"
                return
            }
            message = nil
            try? await refresh()
        } catch {
            try? credentials.delete(reference: reference)
            message = "Unable to authenticate OpenCode endpoint"
        }
    }

    func detachOpenCode(endpoint: ProviderEndpoint) async {
        do {
            let reply = try await client.send(.detachEndpoint(
                provider: .openCode,
                id: endpoint.id
            ))
            guard case .completed = reply else {
                message = reply.failureMessage ?? "Unable to detach OpenCode endpoint"
                return
            }
            if let reference = endpoint.credentialReference {
                try credentials.delete(reference: reference)
            }
            message = nil
            try? await refresh()
        } catch {
            message = "Unable to detach OpenCode endpoint"
        }
    }

    func resolve(_ id: UUID, decision: RequestDecision) async {
        guard canResolve(id) else { return }
        resolvingRequestIDs.insert(id)
        do {
            let reply = try await client.send(.resolveRequest(id, decision))

            // A native route means the daemon cannot act for us: the app must
            // drive the provider's own UI and only then report it started.
            if case .nativeInteraction(let plan) = reply {
                await performNativeInteraction(plan, requestID: id)
                return
            }

            guard case .accepted = reply else {
                resolvingRequestIDs.remove(id)
                message = reply.failureMessage ?? "Unable to resolve request"
                return
            }
            if var request = state.requests[id] {
                request.state = .resolving
                state.requests[id] = request
            }
            try await refresh()
            if state.requests[id]?.state != .pending {
                resolvingRequestIDs.remove(id)
            }
        } catch {
            resolvingRequestIDs.remove(id)
            message = "Unable to resolve request"
        }
    }

    /// Drives the provider's native UI, then tells the daemon the interaction
    /// started. On any failure the request stays pending and the user is told
    /// exactly what AgentHub could not do — no exact-jump claim after a
    /// fallback.
    private func performNativeInteraction(
        _ plan: NativeInteractionPlan,
        requestID: UUID
    ) async {
        do {
            try await nativeExecutor.execute(plan)
            _ = try await client.send(
                .nativeInteractionStarted(requestID: requestID, planID: plan.id)
            )
            try await refresh()
        } catch NativeInteractionError.accessibilityUnavailable {
            message = "Claude was brought forward. Grant Accessibility to let "
                + "AgentHub answer this request for you."
        } catch NativeInteractionError.stalePrompt {
            message = "Claude has moved on from this prompt. Answer it in Claude."
        } catch NativeInteractionError.ambiguousTarget {
            message = "More than one Claude window matched. Answer it in Claude."
        } catch {
            message = "AgentHub could not find this request in Claude. Answer it there."
        }
        resolvingRequestIDs.remove(requestID)
    }

    /// Runs an explicit provider setup action, such as installing or removing
    /// AgentHub's Claude hooks.
    func configure(provider: Provider, action: ProviderConfigurationAction) async {
        do {
            let reply = try await client.send(.configureProvider(provider, action))
            guard case .components(let components) = reply else {
                message = reply.failureMessage
                    ?? "Unable to update \(provider.displayName) setup"
                return
            }
            message = nil
            // Refresh first: it replaces `state` wholesale, and the reported
            // component status is newer than the snapshot's.
            try await refresh()
            for component in components {
                state.components[component.id] = component
            }
        } catch {
            message = "Unable to update \(provider.displayName) setup"
        }
    }

    func send(_ text: String, to sessionID: UUID) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await perform(
            .sendInput(sessionID, AgentInput(text: text, provenance: "AgentHub dashboard")),
            failure: "Unable to send input"
        )
    }

    func handoff(
        source: UUID,
        target: UUID,
        turnLimit: Int,
        note: String?
    ) async {
        await perform(
            .createHandoff(
                source: source,
                target: target,
                turnLimit: max(0, min(turnLimit, 20)),
                note: note
            ),
            failure: "Unable to create handoff"
        )
    }

    func jump(to sessionID: UUID) async {
        do {
            let reply = try await client.send(.jumpTarget(sessionID))
            switch reply {
            case .jump(.agentHubDetail):
                selectedSessionID = sessionID
            case .jump(.terminal):
                message = "Terminal jump is not available for this session"
            case .jump(.application(let bundleID, let windowHint)):
                do {
                    try await jumpOpener.open(
                        bundleID: bundleID,
                        windowHint: windowHint
                    )
                    message = nil
                } catch {
                    message = "Unable to open \(bundleID)"
                }
            case .jump(.unavailable(let reason)):
                message = reason
            case .failure(let reason):
                message = reason
            default:
                message = "Unable to open session"
            }
        } catch {
            message = "Unable to open session"
        }
    }

    func canResolve(_ id: UUID) -> Bool {
        state.requests[id]?.state == .pending && !resolvingRequestIDs.contains(id)
    }

    var selectedSession: AgentSession? {
        guard let selectedSessionID else { return nil }
        return state.sessions[selectedSessionID]
    }

    private func perform(_ command: DaemonCommand, failure: String) async {
        do {
            let reply = try await client.send(command)
            if case .failure(let reason) = reply {
                message = reason
                return
            }
            try await refresh()
        } catch {
            message = failure
        }
    }

    private func refresh() async throws {
        let reply = try await client.send(.getSnapshot)
        guard case .snapshot(let snapshot) = reply else {
            throw DashboardError.invalidSnapshot
        }
        state = snapshot
        if selectedSessionID == nil {
            selectedSessionID = snapshot.sessions.values
                .sorted { $0.lastActivityAt > $1.lastActivityAt }
                .first?.id
        }
    }

    private func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func rollback(_ reference: String?) throws {
        if let reference { try credentials.delete(reference: reference) }
    }
}

private enum DashboardError: Error {
    case invalidSnapshot
}

private extension DaemonReply {
    var failureMessage: String? {
        guard case .failure(let message) = self else { return nil }
        return message
    }
}

extension Provider {
    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .openCode: "OpenCode"
        case .claude: "Claude"
        case .cursor: "Cursor"
        }
    }
}
