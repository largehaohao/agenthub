import Foundation
import AgentHubCore
import AgentHubIPC

public actor DaemonAPI {
    private let coordinator: Coordinator
    private let requests: RequestService
    private let handoffs: HandoffService

    public init(
        coordinator: Coordinator,
        requests: RequestService,
        handoffs: HandoffService
    ) {
        self.coordinator = coordinator
        self.requests = requests
        self.handoffs = handoffs
    }

    public func handle(_ command: DaemonCommand) async -> DaemonReply {
        do {
            switch command {
            case .getSnapshot:
                return .snapshot(await coordinator.snapshot())

            case .launch(let provider, let request):
                return .accepted(try await coordinator.launch(provider: provider, request: request))

            case .attachEndpoint(let attachment):
                return .endpoint(try await coordinator.attachEndpoint(attachment))

            case .authenticateEndpoint(let binding):
                return .endpoint(try await coordinator.authenticateEndpoint(binding))

            case .detachEndpoint(let provider, let id):
                try await coordinator.detachEndpoint(provider: provider, id: id)
                return .completed

            case .resolveRequest(let id, let decision):
                let outcome = try await requests.resolve(id: id, decision: decision)
                try await coordinator.refreshFromStore()
                if case .native(let plan) = outcome {
                    return .nativeInteraction(plan)
                }
                return .accepted(id)

            case .sendInput(let sessionID, let input):
                try await coordinator.send(input, to: sessionID)
                return .accepted(sessionID)

            case .createHandoff(let sourceID, let targetID, let turnLimit, let note):
                let state = await coordinator.snapshot()
                guard let source = state.sessions[sourceID],
                      let target = state.sessions[targetID] else {
                    return .failure("Session not found")
                }
                let createdAt = Date()
                let envelope = MessageEnvelope(
                    id: UUID(),
                    sourceSessionID: sourceID,
                    targetSessionID: targetID,
                    repository: source.repository,
                    cwd: source.cwd,
                    branch: source.branch,
                    turns: Array(source.preview.suffix(max(0, min(turnLimit, 20)))),
                    userNote: note,
                    createdAt: createdAt,
                    expiresAt: createdAt.addingTimeInterval(5 * 60),
                    state: .queued
                )
                let pending = state.requests.values.filter {
                    $0.sessionID == targetID
                }
                try await handoffs.submit(
                    envelope,
                    target: target,
                    pendingRequests: pending
                )
                try await coordinator.refreshFromStore()
                return .accepted(envelope.id)

            case .jumpTarget(let sessionID):
                return .jump(try await coordinator.jumpTarget(for: sessionID))

            case .ingestProviderHook(let hook):
                if let requestID = try await coordinator.ingest(hook) {
                    return .accepted(requestID)
                }
                return .completed

            case .configureProvider(let provider, let action):
                let components = try await coordinator.configure(
                    provider: provider,
                    action: action
                )
                return .components(components)

            case .nativeInteractionStarted(let requestID, let planID):
                try await requests.nativeInteractionStarted(
                    requestID: requestID,
                    planID: planID
                )
                try await coordinator.refreshFromStore()
                return .completed

            case .awaitHookPermission(let requestID, let timeoutMilliseconds):
                let decision = await requests.awaitHookPermission(
                    requestID: requestID,
                    timeoutMilliseconds: timeoutMilliseconds
                )
                return .hookPermission(decision)
            }
        } catch {
            return .failure(publicFailure(for: command))
        }
    }

    private func publicFailure(for command: DaemonCommand) -> String {
        switch command {
        case .getSnapshot: "Snapshot unavailable"
        case .launch(let provider, _): "Unable to launch \(provider.rawValue)"
        case .attachEndpoint: "Unable to attach provider endpoint"
        case .authenticateEndpoint: "Unable to authenticate provider endpoint"
        case .detachEndpoint: "Unable to detach provider endpoint"
        case .resolveRequest: "Unable to resolve request"
        case .sendInput: "Unable to send input"
        case .createHandoff: "Unable to create handoff"
        case .jumpTarget: "Unable to open session"
        case .ingestProviderHook: "Unable to ingest provider hook"
        case .configureProvider(let provider, _): "Unable to configure \(provider.rawValue)"
        case .nativeInteractionStarted: "Unable to record native interaction"
        case .awaitHookPermission: "Unable to await hook permission"
        }
    }
}
