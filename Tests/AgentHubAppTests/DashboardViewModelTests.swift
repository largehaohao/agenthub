import Foundation
import XCTest
import AgentHubCore
import AgentHubIPC
import AgentHubSecurity
@testable import AgentHubApp

@MainActor
final class DashboardViewModelTests: XCTestCase {
    func testClaudeNativeResolutionExecutesPlanThenMarksItStarted() async {
        let fixture = DashboardFixture()
        let plan = nativePlan(requestID: fixture.request.id)
        let client = FakeDaemonClient(
            snapshot: fixture.state,
            resolveReply: .nativeInteraction(plan)
        )
        let executor = RecordingNativeExecutor()
        let model = DashboardViewModel(client: client, nativeExecutor: executor)
        await model.connect()

        await model.resolve(fixture.request.id, decision: .accept)

        let executed = await executor.plans()
        XCTAssertEqual(executed, [plan])
        let commands = await client.recordedCommands
        XCTAssertTrue(commands.contains {
            if case .nativeInteractionStarted(let requestID, let planID) = $0 {
                return requestID == fixture.request.id && planID == plan.id
            }
            return false
        })
    }

    func testFailedNativeInteractionNeverReportsItStarted() async {
        let fixture = DashboardFixture()
        let plan = nativePlan(requestID: fixture.request.id)
        let client = FakeDaemonClient(
            snapshot: fixture.state,
            resolveReply: .nativeInteraction(plan)
        )
        let executor = RecordingNativeExecutor(error: .accessibilityUnavailable)
        let model = DashboardViewModel(client: client, nativeExecutor: executor)
        await model.connect()

        await model.resolve(fixture.request.id, decision: .accept)

        let commands = await client.recordedCommands
        XCTAssertFalse(commands.contains {
            if case .nativeInteractionStarted = $0 { return true }
            return false
        })
        XCTAssertNotNil(model.message)
    }

    func testConfigureClaudeSendsExplicitSetupActionAndStoresComponents() async {
        let fixture = DashboardFixture()
        let component = ProviderComponentStatus(
            provider: .claude,
            component: "hooks",
            available: true,
            version: "2.1.228",
            path: "/tmp/agenthub-claude-hook",
            message: nil,
            changedAt: Date(timeIntervalSince1970: 1)
        )
        let client = FakeDaemonClient(
            snapshot: fixture.state,
            configureReply: .components([component])
        )
        let model = DashboardViewModel(client: client)
        await model.connect()

        await model.configure(provider: .claude, action: .installHooks)

        let commands = await client.recordedCommands
        XCTAssertTrue(commands.contains {
            if case .configureProvider(.claude, .installHooks) = $0 { return true }
            return false
        })
        XCTAssertEqual(model.state.components["claude:hooks"], component)
    }

    func testInstallCodexBarRequiresExplicitViewModelAction() async {
        let fixture = DashboardFixture()
        let component = ProviderComponentStatus(
            provider: .claude,
            component: "codexbar",
            available: true,
            version: nil,
            path: "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI",
            message: nil,
            changedAt: Date(timeIntervalSince1970: 1)
        )
        let client = FakeDaemonClient(
            snapshot: fixture.state,
            configureReply: .components([component])
        )
        let model = DashboardViewModel(client: client)
        await model.connect()

        await model.installCodexBar()

        let commands = await client.recordedCommands
        XCTAssertTrue(commands.contains {
            if case .configureProvider(.claude, .installQuotaHelper) = $0 { return true }
            return false
        })
        XCTAssertEqual(model.state.components["claude:codexbar"], component)
    }

    func testRefreshClaudeQuotaUsesTheQuotaAction() async {
        let fixture = DashboardFixture()
        let client = FakeDaemonClient(
            snapshot: fixture.state,
            configureReply: .components([])
        )
        let model = DashboardViewModel(client: client)
        await model.connect()

        await model.refreshClaudeQuota()

        let commands = await client.recordedCommands
        XCTAssertTrue(commands.contains {
            if case .configureProvider(.claude, .refreshQuota) = $0 { return true }
            return false
        })
    }

    func testClaudeQuotaPresentationUsesWindowAndPlanLabels() throws {
        let now = Date(timeIntervalSince1970: 20_000)
        let window = try QuotaWindow(
            provider: .claude,
            accountID: "user@example.com",
            windowID: "weekly",
            label: "Weekly",
            plan: "Pro",
            usedPercent: 40,
            windowDuration: 604_800,
            resetsAt: Date(timeIntervalSince1970: 600_000),
            fetchedAt: Date(timeIntervalSince1970: 1_000),
            source: "codexbar"
        )

        let item = QuotaPresentation(window: window, now: now)

        XCTAssertEqual(item.title, "Claude · Weekly")
        XCTAssertEqual(item.accountPlan, "user@example.com · Pro")
        XCTAssertTrue(item.isStale)
    }

    func testUnlabeledQuotaPresentationFallsBackToDuration() throws {
        let now = Date(timeIntervalSince1970: 1_100)
        let window = try QuotaWindow(
            provider: .codex,
            accountID: "personal",
            usedPercent: 10,
            windowDuration: 18_000,
            resetsAt: Date(timeIntervalSince1970: 600_000),
            fetchedAt: Date(timeIntervalSince1970: 1_000),
            source: "codex-app-server"
        )

        let item = QuotaPresentation(window: window, now: now)

        XCTAssertEqual(item.title, "Codex · 5h")
        XCTAssertEqual(item.accountPlan, "personal")
        XCTAssertFalse(item.isStale)
    }

    private func nativePlan(requestID: UUID) -> NativeInteractionPlan {
        NativeInteractionPlan(
            id: UUID(),
            provider: .claude,
            requestID: requestID,
            bundleID: "com.anthropic.claudefordesktop",
            windowHint: nil,
            sessionNativeID: "abc123",
            promptFingerprint: "fingerprint",
            operation: .choose(label: "Yes")
        )
    }

    func testLaunchOpenCodeSendsGenericProviderCommand() async {
        let fixture = DashboardFixture()
        let client = FakeDaemonClient(snapshot: fixture.state)
        let model = DashboardViewModel(client: client)
        await model.connect()

        await model.launch(
            provider: .openCode,
            cwd: "/repo",
            prompt: "work",
            agent: nil,
            model: nil
        )

        let commands = await client.recordedCommands
        guard case .launch(.openCode, let request) = commands.dropFirst().first else {
            return XCTFail("expected OpenCode launch")
        }
        XCTAssertEqual(request.cwd, "/repo")
    }

    func testFailedAttachDeletesNewKeychainReferenceAndNeverSendsSecret() async throws {
        let fixture = DashboardFixture()
        let client = FakeDaemonClient(
            snapshot: fixture.state,
            attachReply: .failure("Unable to attach OpenCode endpoint")
        )
        let credentials = RecordingCredentialStore()
        let model = DashboardViewModel(client: client, credentials: credentials)
        await model.connect()

        await model.attachOpenCode(
            url: "http://127.0.0.1:41789",
            password: "secret"
        )

        XCTAssertEqual(credentials.savedSecrets.map(\.secret), ["secret"])
        XCTAssertEqual(
            credentials.deletedReferences,
            credentials.savedSecrets.map(\.reference)
        )
        let commandData = try JSONEncoder.agentHub.encode(await client.recordedCommands)
        let commandText = String(decoding: commandData, as: UTF8.self)
        XCTAssertFalse(commandText.contains("secret"))
    }

    func testDiscoveredEndpointAuthenticationSendsOnlyKeychainReference() async throws {
        let fixture = DashboardFixture()
        let endpoint = fixture.openCodeEndpoint
        let client = FakeDaemonClient(
            snapshot: fixture.state,
            authenticateReply: .endpoint(endpoint)
        )
        let credentials = RecordingCredentialStore()
        let model = DashboardViewModel(client: client, credentials: credentials)
        await model.connect()

        await model.authenticateOpenCode(endpointID: endpoint.id, password: "secret")

        let commands = await client.recordedCommands
        guard let binding = commands.compactMap({ command -> ProviderEndpointCredentialBinding? in
            guard case .authenticateEndpoint(let binding) = command else { return nil }
            return binding
        }).first else {
            return XCTFail("expected endpoint authentication")
        }
        XCTAssertEqual(binding.endpointID, endpoint.id)
        XCTAssertNotEqual(binding.credentialReference, "secret")
        let commandData = try JSONEncoder.agentHub.encode(commands)
        XCTAssertFalse(String(decoding: commandData, as: UTF8.self).contains("secret"))
        XCTAssertTrue(credentials.deletedReferences.isEmpty)
    }

    func testSuccessfulAttachKeepsKeychainReference() async {
        let fixture = DashboardFixture()
        let client = FakeDaemonClient(
            snapshot: fixture.state,
            attachReply: .endpoint(fixture.openCodeEndpoint)
        )
        let credentials = RecordingCredentialStore()
        let model = DashboardViewModel(client: client, credentials: credentials)
        await model.connect()

        await model.attachOpenCode(
            url: fixture.openCodeEndpoint.baseURL,
            password: "secret"
        )

        XCTAssertEqual(credentials.savedSecrets.count, 1)
        XCTAssertTrue(credentials.deletedReferences.isEmpty)
        XCTAssertNil(model.message)
    }

    func testFixtureContainsMixedOpenCodeDataWithoutInventingQuota() {
        let state = AppEnvironment.fixtureState()

        XCTAssertTrue(state.sessions.values.contains { $0.providerRef.provider == .openCode })
        XCTAssertTrue(state.requests.values.contains {
            $0.provider == .openCode && $0.kind == .choice
        })
        XCTAssertTrue(state.endpoints.values.contains { $0.provider == .openCode })
        XCTAssertFalse(state.quotas.values.contains { $0.provider == .openCode })
    }

    func testDetachAcknowledgesDaemonBeforeDeletingKeychainReference() async {
        let fixture = DashboardFixture()
        let log = RecordingOperationLog()
        let client = FakeDaemonClient(
            snapshot: fixture.state,
            detachReply: .completed,
            operationLog: log
        )
        let credentials = RecordingCredentialStore(operationLog: log)
        let model = DashboardViewModel(client: client, credentials: credentials)
        await model.connect()

        await model.detachOpenCode(endpoint: fixture.openCodeEndpoint)

        XCTAssertEqual(
            log.values.suffix(2),
            ["daemon.detach", "credentials.delete"]
        )
    }
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

    func testJumpApplicationUsesInjectedOpener() async {
        let fixture = DashboardFixture()
        let client = FakeDaemonClient(
            snapshot: fixture.state,
            jump: .application(
                bundleID: "com.googlecode.iterm2",
                windowHint: "OpenCode ses_1"
            )
        )
        let opener = RecordingJumpOpener()
        let model = DashboardViewModel(client: client, jumpOpener: opener)
        await model.connect()

        await model.jump(to: fixture.session.id)

        XCTAssertEqual(
            opener.opened,
            [.init(bundleID: "com.googlecode.iterm2", windowHint: "OpenCode ses_1")]
        )
        XCTAssertNil(model.message)
    }

    func testUnavailableJumpDisplaysProviderReasonWithoutOpening() async {
        let fixture = DashboardFixture()
        let client = FakeDaemonClient(
            snapshot: fixture.state,
            jump: .unavailable("OpenCode route is stale")
        )
        let opener = RecordingJumpOpener()
        let model = DashboardViewModel(client: client, jumpOpener: opener)
        await model.connect()

        await model.jump(to: fixture.session.id)

        XCTAssertTrue(opener.opened.isEmpty)
        XCTAssertEqual(model.message, "OpenCode route is stale")
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

@MainActor
private final class RecordingJumpOpener: JumpOpening {
    struct Call: Equatable {
        let bundleID: String
        let windowHint: String?
    }

    private(set) var opened: [Call] = []

    func open(bundleID: String, windowHint: String?) async throws {
        opened.append(.init(bundleID: bundleID, windowHint: windowHint))
    }
}

private actor FakeDaemonClient: DaemonClientProtocol {
    private let snapshot: AgentHubState
    private let jump: JumpTarget
    private(set) var recordedCommands: [DaemonCommand] = []
    private(set) var connectAttempts = 0
    private var remainingConnectFailures: Int
    private let attachReply: DaemonReply
    private let authenticateReply: DaemonReply
    private let detachReply: DaemonReply
    private let resolveReply: DaemonReply?
    private let configureReply: DaemonReply
    private let operationLog: RecordingOperationLog?

    init(
        snapshot: AgentHubState,
        jump: JumpTarget = .unavailable("fixture"),
        connectFailures: Int = 0,
        attachReply: DaemonReply = .failure("unsupported fixture command"),
        authenticateReply: DaemonReply = .failure("unsupported fixture command"),
        detachReply: DaemonReply = .failure("unsupported fixture command"),
        resolveReply: DaemonReply? = nil,
        configureReply: DaemonReply = .failure("unsupported fixture command"),
        operationLog: RecordingOperationLog? = nil
    ) {
        self.snapshot = snapshot
        self.jump = jump
        remainingConnectFailures = connectFailures
        self.attachReply = attachReply
        self.authenticateReply = authenticateReply
        self.detachReply = detachReply
        self.resolveReply = resolveReply
        self.configureReply = configureReply
        self.operationLog = operationLog
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
            return resolveReply ?? .accepted(id)
        case .configureProvider:
            return configureReply
        case .nativeInteractionStarted:
            return .completed
        case .launch:
            return .accepted(snapshot.sessions.keys.first ?? UUID())
        case .attachEndpoint:
            return attachReply
        case .authenticateEndpoint:
            return authenticateReply
        case .detachEndpoint:
            operationLog?.record("daemon.detach")
            return detachReply
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
    let openCodeEndpoint: ProviderEndpoint

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
        openCodeEndpoint = ProviderEndpoint(
            id: "openCode:tui:42",
            provider: .openCode,
            origin: .tui,
            baseURL: "http://127.0.0.1:41789",
            credentialReference: "existing-reference",
            connected: true,
            version: "1.18.10",
            lastSeenAt: now
        )
        state = AgentHubState(
            sessions: [session.id: session],
            requests: [request.id: request],
            endpoints: [openCodeEndpoint.id: openCodeEndpoint]
        )
    }
}

private final class RecordingOperationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] { lock.withLock { storage } }
    func record(_ value: String) { lock.withLock { storage.append(value) } }
}

private final class RecordingCredentialStore: CredentialStoring, @unchecked Sendable {
    struct SavedSecret: Equatable {
        let secret: String
        let reference: String
    }

    private let lock = NSLock()
    private var savedStorage: [SavedSecret] = []
    private var deletedStorage: [String] = []
    private let operationLog: RecordingOperationLog?

    init(operationLog: RecordingOperationLog? = nil) {
        self.operationLog = operationLog
    }

    var savedSecrets: [SavedSecret] { lock.withLock { savedStorage } }
    var deletedReferences: [String] { lock.withLock { deletedStorage } }

    func save(_ secret: String, reference: String) throws {
        lock.withLock { savedStorage.append(.init(secret: secret, reference: reference)) }
    }

    func read(reference: String) throws -> String { "secret" }

    func delete(reference: String) throws {
        lock.withLock { deletedStorage.append(reference) }
        operationLog?.record("credentials.delete")
    }
}

private actor RecordingNativeExecutor: NativeInteractionExecuting {
    private var executed: [NativeInteractionPlan] = []
    private let error: NativeInteractionError?

    init(error: NativeInteractionError? = nil) {
        self.error = error
    }

    func plans() -> [NativeInteractionPlan] { executed }

    func execute(_ plan: NativeInteractionPlan) async throws {
        if let error { throw error }
        executed.append(plan)
    }
}
