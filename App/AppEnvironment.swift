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

    private static func fixtureState() -> AgentHubState {
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
        return AgentHubState(
            sessions: [session.id: session],
            nodes: [node.id: node],
            requests: [request.id: request],
            quotas: [primary.id: primary, secondary.id: secondary],
            adapterHealth: [.codex: AdapterHealth(connected: true, changedAt: now)]
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
        case .attachEndpoint, .authenticateEndpoint, .detachEndpoint:
            return .failure("Endpoint changes are unavailable in fixture mode")
        }
    }

    func events() async -> AsyncStream<DaemonEvent> {
        AsyncStream { _ in }
    }
}
