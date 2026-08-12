import Foundation
import AgentHubCore
import AgentHubIPC

enum AppEnvironment {
    static func makeDaemonClient(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> any DaemonClientProtocol {
        if environment["AGENTHUB_FIXTURE_MODE"] == "1" {
            return FixtureDaemonClient(state: fixtureState())
        }
        return DaemonClient(socketPath: socketPath(fileManager: fileManager))
    }

    static func socketPath(fileManager: FileManager = .default) -> String {
        let applicationSupport = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("AgentHub", isDirectory: true)
            .appendingPathComponent("agenthub.sock")
            .path
    }

    static func fixtureState() -> AgentHubState {
        let now = Date()
        let rootID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let session = AgentSession(
            id: rootID,
            providerRef: ProviderSessionRef(
                provider: .codex,
                accountID: "fixture",
                nativeID: "fixture-codex-root"
            ),
            title: "AgentHub fixture session",
            surface: "Codex app-server",
            ownership: .managed,
            status: .waitingPermission,
            rootID: rootID,
            cwd: "/tmp/agenthub-fixture",
            repository: "agenthub",
            branch: "main",
            lastActivityAt: now,
            capabilities: [
                .discover: .l1, .launch: .l1, .status: .l1, .children: .l1,
                .recentTurns: .l1, .sendInput: .l1, .resolveRequest: .l1,
                .jump: .l1, .quota: .l1,
            ],
            preview: [VisibleTurn(
                id: "fixture-turn",
                role: "assistant",
                text: "Fixture mode is ready without contacting Codex.",
                createdAt: now
            )]
        )
        let node = AgentNode(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            sessionID: rootID,
            nativeID: "fixture-subagent",
            parentNativeID: "fixture-codex-root",
            kind: "subagent",
            status: .working,
            lastActivityAt: now
        )
        let request = PendingRequest(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
            provider: .codex,
            providerRequestID: "fixture-approval",
            sessionID: rootID,
            threadID: "fixture-codex-root",
            kind: .permission,
            title: "Allow fixture command?",
            detail: "This is a local UI fixture; no command will run.",
            allowedActions: ["accept", "decline"],
            state: .pending,
            reliability: .l1,
            createdAt: now,
            expiresAt: now.addingTimeInterval(300)
        )
        let primary = try! QuotaWindow(
            provider: .codex,
            accountID: "fixture",
            usedPercent: 32,
            windowDuration: 5 * 60 * 60,
            resetsAt: now.addingTimeInterval(2 * 60 * 60),
            fetchedAt: now,
            source: "fixture"
        )
        let secondary = try! QuotaWindow(
            provider: .codex,
            accountID: "fixture",
            usedPercent: 58,
            windowDuration: 7 * 24 * 60 * 60,
            resetsAt: now.addingTimeInterval(3 * 24 * 60 * 60),
            fetchedAt: now,
            source: "fixture"
        )
        let openCodeID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let openCodeSession = AgentSession(
            id: openCodeID,
            providerRef: ProviderSessionRef(
                provider: .openCode,
                accountID: "fixture",
                nativeID: "ses_fixture"
            ),
            title: "OpenCode TUI fixture",
            surface: "OpenCode TUI",
            ownership: .discovered,
            status: .idle,
            rootID: openCodeID,
            cwd: "/tmp/opencode-fixture",
            repository: "agenthub",
            branch: "feat/opencode",
            lastActivityAt: now.addingTimeInterval(-30),
            capabilities: [
                .discover: .l1, .status: .l1, .children: .l1,
                .recentTurns: .l1, .sendInput: .l1, .resolveRequest: .l1,
                .jump: .l1,
            ],
            preview: [VisibleTurn(
                id: "opencode-fixture-turn",
                role: "assistant",
                text: "OpenCode fixture is ready without contacting a server.",
                createdAt: now
            )]
        )
        let openCodeQuestion = PendingRequest(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            provider: .openCode,
            providerRequestID: "que_fixture",
            sessionID: openCodeID,
            threadID: "ses_fixture",
            kind: .choice,
            title: "OpenCode question",
            detail: "Choose the implementation language and add an optional note.",
            allowedActions: ["answer", "cancel"],
            fields: [
                RequestField(
                    id: "0",
                    prompt: "Language",
                    choices: ["Swift", "Rust"]
                ),
                RequestField(
                    id: "1",
                    prompt: "Optional note",
                    allowsFreeText: true
                ),
            ],
            state: .pending,
            reliability: .l1,
            createdAt: now
        )
        let tuiEndpoint = ProviderEndpoint(
            id: "openCode:tui:fixture",
            provider: .openCode,
            origin: .tui,
            baseURL: "http://127.0.0.1:41789",
            connected: true,
            version: "1.18.10",
            lastSeenAt: now
        )
        let manualEndpoint = ProviderEndpoint(
            id: "openCode:manual:fixture",
            provider: .openCode,
            origin: .manual,
            baseURL: "http://127.0.0.1:41790",
            credentialReference: "fixture-keychain-reference",
            connected: true,
            version: "1.18.10",
            lastSeenAt: now
        )
        return AgentHubState(
            sessions: [session.id: session, openCodeSession.id: openCodeSession],
            nodes: [node.id: node],
            requests: [request.id: request, openCodeQuestion.id: openCodeQuestion],
            quotas: [primary.id: primary, secondary.id: secondary],
            adapterHealth: [
                .codex: AdapterHealth(connected: true, changedAt: now),
                .openCode: AdapterHealth(connected: true, changedAt: now),
            ],
            endpoints: [
                tuiEndpoint.id: tuiEndpoint,
                manualEndpoint.id: manualEndpoint,
            ]
        )
    }
}

private actor FixtureDaemonClient: DaemonClientProtocol {
    private var state: AgentHubState

    init(state: AgentHubState) {
        self.state = state
    }

    func connect() async throws {}

    func send(_ command: DaemonCommand) async throws -> DaemonReply {
        switch command {
        case .getSnapshot:
            return .snapshot(state)
        case .resolveRequest(let id, _):
            if var request = state.requests[id] {
                request.state = .resolved
                state.requests[id] = request
            }
            return .accepted(id)
        case .sendInput(let id, _), .createHandoff(_, let id, _, _):
            return .accepted(id)
        case .jumpTarget(let id):
            guard let session = state.sessions[id] else {
                return .failure("Session not found")
            }
            return .jump(.agentHubDetail(sessionNativeID: session.providerRef.nativeID))
        case .launch:
            return .accepted(state.sessions.keys.first ?? UUID())
        case .attachEndpoint(let attachment):
            let endpoint = ProviderEndpoint(
                id: "fixture:\(UUID().uuidString)",
                provider: attachment.provider,
                origin: .manual,
                baseURL: attachment.baseURL,
                credentialReference: attachment.credentialReference,
                connected: true,
                version: "fixture",
                lastSeenAt: Date()
            )
            state.endpoints[endpoint.id] = endpoint
            return .endpoint(endpoint)
        case .authenticateEndpoint(let binding):
            guard let existing = state.endpoints[binding.endpointID] else {
                return .failure("Endpoint not found")
            }
            let endpoint = ProviderEndpoint(
                id: existing.id,
                provider: existing.provider,
                origin: existing.origin,
                baseURL: existing.baseURL,
                credentialReference: binding.credentialReference,
                connected: true,
                version: existing.version,
                lastSeenAt: Date()
            )
            state.endpoints[endpoint.id] = endpoint
            return .endpoint(endpoint)
        case .detachEndpoint(_, let id):
            state.endpoints.removeValue(forKey: id)
            return .completed
        case .ingestProviderHook, .nativeInteractionStarted:
            return .completed
        case .configureProvider:
            return .components(Array(state.components.values))
        }
    }

    func events() async -> AsyncStream<DaemonEvent> {
        AsyncStream { _ in }
    }
}
