import Foundation
import XCTest
import AgentHubCore
import AgentHubIPC
@testable import AgentHubApp

@MainActor
final class DashboardViewModelTests: XCTestCase {
    func testResolveDisablesButtonsAfterSubmission() async {
        let fixture = DashboardFixture()
        let client = FakeDaemonClient(snapshot: fixture.state)
        let model = DashboardViewModel(client: client)
        await model.connect()

        await model.resolve(fixture.request.id, decision: .accept)

        XCTAssertFalse(model.canResolve(fixture.request.id))
        let commands = await client.recordedCommands
        XCTAssertEqual(commands.count, 3)
        guard case .resolveRequest(let id, .accept) = commands[1] else {
            return XCTFail("expected resolve command")
        }
        XCTAssertEqual(id, fixture.request.id)
    }

    func testJumpSelectsManagedDetail() async {
        let fixture = DashboardFixture()
        let client = FakeDaemonClient(
            snapshot: fixture.state,
            jump: .agentHubDetail(sessionNativeID: fixture.session.providerRef.nativeID)
        )
        let model = DashboardViewModel(client: client)
        await model.connect()

        await model.jump(to: fixture.session.id)

        XCTAssertEqual(model.selectedSessionID, fixture.session.id)
    }

    func testInitialConnectionFailureRetriesUntilDaemonIsAvailable() async {
        let fixture = DashboardFixture()
        let client = FakeDaemonClient(snapshot: fixture.state, connectFailures: 1)
        let model = DashboardViewModel(
            client: client,
            retryDelay: { _ in .milliseconds(1) }
        )

        await model.connect()

        XCTAssertEqual(model.connection, ConnectionState.connected)
        let connectAttempts = await client.connectAttempts
        XCTAssertEqual(connectAttempts, 2)
        XCTAssertEqual(model.state.sessions.count, 1)
    }
}

private actor FakeDaemonClient: DaemonClientProtocol {
    private let snapshot: AgentHubState
    private let jump: JumpTarget
    private(set) var recordedCommands: [DaemonCommand] = []
    private(set) var connectAttempts = 0
    private var remainingConnectFailures: Int

    init(
        snapshot: AgentHubState,
        jump: JumpTarget = .unavailable("fixture"),
        connectFailures: Int = 0
    ) {
        self.snapshot = snapshot
        self.jump = jump
        remainingConnectFailures = connectFailures
    }

    func connect() async throws {
        connectAttempts += 1
        if remainingConnectFailures > 0 {
            remainingConnectFailures -= 1
            throw IPCError.disconnected
        }
    }

    func send(_ command: DaemonCommand) async throws -> DaemonReply {
        recordedCommands.append(command)
        switch command {
        case .getSnapshot:
            return .snapshot(snapshot)
        case .jumpTarget:
            return .jump(jump)
        case .resolveRequest(let id, _):
            return .accepted(id)
        default:
            return .failure("unsupported fixture command")
        }
    }

    func events() async -> AsyncStream<DaemonEvent> {
        AsyncStream { $0.finish() }
    }
}

private struct DashboardFixture {
    let session: AgentSession
    let request: PendingRequest
    let state: AgentHubState

    init() {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        session = AgentSession(
            id: sessionID,
            providerRef: ProviderSessionRef(
                provider: .codex,
                accountID: "fixture",
                nativeID: "codex-1"
            ),
            title: "Managed Codex session",
            surface: "AgentHub",
            ownership: .managed,
            status: .idle,
            rootID: sessionID,
            cwd: "/tmp/agenthub-fixture",
            lastActivityAt: now,
            capabilities: [.jump: .l1, .resolveRequest: .l1, .sendInput: .l1],
            preview: []
        )
        request = PendingRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            provider: .codex,
            providerRequestID: "approval-1",
            sessionID: sessionID,
            threadID: "codex-1",
            kind: .permission,
            title: "Allow command?",
            detail: "Run tests",
            allowedActions: ["accept", "decline"],
            state: .pending,
            reliability: .l1,
            createdAt: now
        )
        state = AgentHubState(
            sessions: [session.id: session],
            requests: [request.id: request]
        )
    }
}
