import Foundation
import XCTest
import AgentHubCore
import AgentHubSecurity
@testable import AgentHubOpenCode

final class OpenCodeHybridAdapterTests: XCTestCase {
    func testJumpSelectsTUISessionBeforeReturningOwningApplication() async throws {
        let api = FakeOpenCodeAPI(
            sessions: [session("ses_1", updated: 1_700_000_001_000)]
        )
        let adapter = makeAdapter(
            endpoints: [endpoint(
                "tui",
                origin: .tui,
                applicationBundleID: "com.googlecode.iterm2"
            )],
            clients: ["tui": api]
        )
        _ = try await adapter.reconcile()

        let target = await adapter.jumpTarget(for: ProviderSessionRef(
            provider: .openCode,
            accountID: "local-default",
            nativeID: "ses_1"
        ))

        let selectedSessions = await api.selectedSessions()
        XCTAssertEqual(selectedSessions, ["ses_1"])
        XCTAssertEqual(
            target,
            .application(
                bundleID: "com.googlecode.iterm2",
                windowHint: "OpenCode ses_1"
            )
        )
    }

    func testJumpFallsBackToAgentHubDetailWhenSelectionAndSurfaceAreUnavailable() async throws {
        let api = FakeOpenCodeAPI(
            sessions: [session("ses_1", updated: 1_700_000_001_000)],
            selectSessionError: .httpStatus(404)
        )
        let adapter = makeAdapter(
            endpoints: [endpoint("managed", origin: .managed)],
            clients: ["managed": api]
        )
        _ = try await adapter.reconcile()

        let target = await adapter.jumpTarget(for: ProviderSessionRef(
            provider: .openCode,
            accountID: "local-default",
            nativeID: "ses_1"
        ))

        let selectedSessions = await api.selectedSessions()
        XCTAssertEqual(selectedSessions, ["ses_1"])
        XCTAssertEqual(target, .agentHubDetail(sessionNativeID: "ses_1"))
    }

    func testReconcileMergesSessionAndBuildsExplicitChildTree() async throws {
        let desktopAPI = FakeOpenCodeAPI(
            sessions: [
                session("ses_root", title: "Desktop root", updated: 1_700_000_001_000),
                session("ses_child", parentID: "ses_root", title: "Child", updated: 1_700_000_003_000),
            ],
            statuses: ["ses_root": .init(type: "busy", attempt: nil, message: nil, next: nil)]
        )
        let tuiAPI = FakeOpenCodeAPI(
            sessions: [session("ses_root", title: "Newest root", updated: 1_700_000_004_000)],
            statuses: ["ses_root": .init(type: "idle", attempt: nil, message: nil, next: nil)]
        )
        let adapter = makeAdapter(
            endpoints: [endpoint("desktop", origin: .desktop), endpoint("tui", origin: .tui)],
            clients: ["desktop": desktopAPI, "tui": tuiAPI]
        )

        let snapshot = try await adapter.reconcile()

        XCTAssertEqual(snapshot.sessions.map(\.providerRef.nativeID), ["ses_root"])
        XCTAssertEqual(snapshot.sessions.first?.title, "Newest root")
        XCTAssertEqual(snapshot.sessions.first?.surface, "OpenCode Desktop · TUI")
        XCTAssertEqual(snapshot.sessions.first?.status, .idle)
        XCTAssertEqual(snapshot.nodes.map(\.nativeID), ["ses_child"])
        XCTAssertEqual(snapshot.nodes.first?.parentNativeID, "ses_root")
        XCTAssertEqual(snapshot.nodes.first?.status, .completed)
        XCTAssertTrue(snapshot.quotas.isEmpty)
        XCTAssertEqual(snapshot.endpoints.map(\.id), ["desktop", "tui"])
    }

    func testRecentTurnsDeduplicatesPartsAndClampsToTwenty() async throws {
        let api = FakeOpenCodeAPI(
            sessions: [session("ses_root", updated: 1_700_000_001_000)],
            messages: (0..<25).map { index in
                message(
                    id: "msg_\(index)",
                    created: Int64(1_700_000_000_000 + index),
                    parts: [
                        ("part_\(index)", "line \(index)"),
                        ("part_\(index)", "duplicate"),
                    ]
                )
            }
        )
        let adapter = makeAdapter(
            endpoints: [endpoint("tui", origin: .tui)],
            clients: ["tui": api]
        )
        let reference = ProviderSessionRef(
            provider: .openCode,
            accountID: "local-default",
            nativeID: "ses_root"
        )
        _ = try await adapter.reconcile()

        let turns = try await adapter.recentTurns(for: reference, limit: 100)
        let messageLimits = await api.messageLimits()

        XCTAssertEqual(turns.count, 20)
        XCTAssertEqual(turns.first?.id, "msg_0")
        XCTAssertEqual(turns.first?.text, "line 0")
        XCTAssertFalse(turns.contains { $0.text.contains("duplicate") })
        XCTAssertEqual(messageLimits, [20, 20])
    }

    func testSendRequiresExactNativeIDAndDirectoryRoute() async throws {
        let api = FakeOpenCodeAPI(sessions: [session("ses_known", updated: 1_700_000_001_000)])
        let adapter = makeAdapter(
            endpoints: [endpoint("tui", origin: .tui)],
            clients: ["tui": api]
        )
        _ = try await adapter.reconcile()
        let missing = ProviderSessionRef(
            provider: .openCode,
            accountID: "local-default",
            nativeID: "ses_missing"
        )

        do {
            try await adapter.send(AgentInput(text: "hello"), to: missing)
            XCTFail("expected exact-route failure")
        } catch {
            XCTAssertEqual(error as? OpenCodeAdapterError, .staleRoute)
        }
        let prompts = await api.prompts()
        XCTAssertEqual(prompts, [])
    }

    func testAcceptedLaunchIsNotCreatedAgainWhenInitialPromptFails() async throws {
        let managedEndpoint = endpoint("managed", origin: .managed)
        let api = FakeOpenCodeAPI(
            sessions: [],
            createdSession: session("ses_created", title: "Created", updated: 1_700_000_001_000),
            promptError: URLError(.cannotConnectToHost)
        )
        let managed = FakeManagedOpenCodeServer(endpoint: managedEndpoint)
        let adapter = makeAdapter(
            endpoints: [],
            clients: ["managed": api],
            managedServer: managed
        )
        let request = LaunchRequest(
            clientRequestID: "launch-1",
            cwd: "/tmp/repository",
            prompt: "Build it",
            agent: "build",
            model: .init(providerID: "openai", modelID: "gpt-5")
        )

        do {
            _ = try await adapter.launch(request)
            XCTFail("expected prompt failure")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }
        let recoveredReference = try await adapter.launch(request)
        let ensureCount = await managed.ensureCount()
        let createCount = await api.createCount()
        let promptCount = await api.promptCount()

        XCTAssertEqual(recoveredReference.nativeID, "ses_created")
        XCTAssertEqual(ensureCount, 1)
        XCTAssertEqual(createCount, 1)
        XCTAssertEqual(promptCount, 1)
        let snapshot = try await adapter.reconcile()
        XCTAssertEqual(snapshot.sessions.map(\.providerRef.nativeID), ["ses_created"])
    }

    func testPermissionAndOrderedQuestionBecomeNormalizedRequests() async throws {
        let api = FakeOpenCodeAPI(
            sessions: [session("ses_root", updated: 1_700_000_001_000)],
            permissions: [
                .init(
                    id: "per_1",
                    sessionID: "ses_root",
                    permission: "bash",
                    patterns: ["swift test"],
                    always: ["swift test"]
                ),
            ],
            questions: [
                .init(
                    id: "que_1",
                    sessionID: "ses_root",
                    questions: [
                        .init(
                            question: "Choose a language",
                            header: "Language",
                            options: [
                                .init(label: "Swift", description: "Use Swift"),
                                .init(label: "Rust", description: "Use Rust"),
                            ],
                            multiple: false,
                            custom: false
                        ),
                        .init(
                            question: "Optional note",
                            header: "Note",
                            options: [],
                            multiple: false,
                            custom: true
                        ),
                    ]
                ),
            ]
        )
        let adapter = makeAdapter(
            endpoints: [endpoint("desktop", origin: .desktop)],
            clients: ["desktop": api]
        )

        let snapshot = try await adapter.reconcile()
        let permission = try XCTUnwrap(snapshot.requests.first { $0.kind == .permission })
        let question = try XCTUnwrap(snapshot.requests.first { $0.kind == .choice })

        XCTAssertTrue(snapshot.requestsAreAuthoritative)
        XCTAssertEqual(permission.allowedActions, ["once", "always", "reject"])
        XCTAssertEqual(permission.threadID, "ses_root")
        XCTAssertEqual(question.fields.map(\.id), ["0", "1"])
        XCTAssertEqual(question.fields[0].choices, ["Swift", "Rust"])
        XCTAssertTrue(question.fields[1].allowsFreeText)
    }

    func testResolveMapsPermissionAndPreservesOrderedQuestionAnswers() async throws {
        let api = FakeOpenCodeAPI(
            sessions: [session("ses_root", updated: 1_700_000_001_000)],
            permissions: [
                .init(
                    id: "per_1",
                    sessionID: "ses_root",
                    permission: "bash",
                    patterns: [],
                    always: []
                ),
            ],
            questions: [
                .init(id: "que_1", sessionID: "ses_root", questions: []),
            ]
        )
        let adapter = makeAdapter(
            endpoints: [endpoint("tui", origin: .tui)],
            clients: ["tui": api]
        )
        _ = try await adapter.reconcile()
        let permission = ProviderRequestRef(
            provider: .openCode,
            requestID: "per_1",
            threadID: "ses_root"
        )
        let question = ProviderRequestRef(
            provider: .openCode,
            requestID: "que_1",
            threadID: "ses_root"
        )

        try await adapter.resolve(permission, decision: .accept)
        try await adapter.resolve(permission, decision: .acceptForSession)
        try await adapter.resolve(permission, decision: .decline)
        try await adapter.resolve(question, decision: .answers([["Swift"], ["free text"]]))
        let permissionReplies = await api.recordedPermissionReplies()
        let questionReplies = await api.recordedQuestionReplies()

        XCTAssertEqual(permissionReplies.map(\.reply), [.once, .always, .reject])
        XCTAssertEqual(questionReplies.first?.answers, [["Swift"], ["free text"]])
    }

    func testEventStreamStartsOneRelayAndReconcilesPermissionEvent() async throws {
        let api = FakeOpenCodeAPI(
            sessions: [session("ses_root", updated: 1_700_000_001_000)]
        )
        let adapter = makeAdapter(
            endpoints: [endpoint("desktop", origin: .desktop)],
            clients: ["desktop": api]
        )
        _ = try await adapter.reconcile()

        let firstStream = await adapter.eventStream()
        _ = await adapter.eventStream()
        for _ in 0..<100 {
            if await api.eventSubscriptionCount() > 0 { break }
            await Task.yield()
        }
        let subscriptions = await api.eventSubscriptionCount()
        guard subscriptions == 1 else {
            return XCTFail("expected exactly one endpoint relay, got \(subscriptions)")
        }

        await api.setPermissions([
            .init(
                id: "per_live",
                sessionID: "ses_root",
                permission: "bash",
                patterns: ["swift test"],
                always: []
            ),
        ])
        let eventTask = Task { () -> AgentEvent? in
            for await event in firstStream { return event }
            return nil
        }
        await api.emitEvent(.init(type: "permission.updated", propertiesJSON: Data("{}".utf8)))

        guard case .requestUpserted(let request) = await eventTask.value else {
            return XCTFail("missing normalized live permission event")
        }
        XCTAssertEqual(request.providerRequestID, "per_live")
        XCTAssertEqual(
            request.id,
            stableOpenCodeUUID(accountID: "local-default", nativeID: "request:per_live")
        )
        await adapter.shutdown()
    }

    func testAlreadyResolvedPermissionMapsToSharedIdempotentError() async throws {
        let api = FakeOpenCodeAPI(
            sessions: [session("ses_root", updated: 1_700_000_001_000)],
            permissions: [
                .init(
                    id: "per_1",
                    sessionID: "ses_root",
                    permission: "bash",
                    patterns: [],
                    always: []
                ),
            ],
            permissionReplyError: .alreadyResolved
        )
        let adapter = makeAdapter(
            endpoints: [endpoint("tui", origin: .tui)],
            clients: ["tui": api]
        )
        _ = try await adapter.reconcile()
        let request = ProviderRequestRef(
            provider: .openCode,
            requestID: "per_1",
            threadID: "ses_root"
        )

        do {
            try await adapter.resolve(request, decision: .accept)
            XCTFail("expected idempotent already-resolved error")
        } catch {
            XCTAssertEqual(error as? AdapterOperationError, .requestAlreadyResolved)
        }
    }

    func testRestoredDesktopCredentialWaitsForProcessRediscovery() async throws {
        let api = FakeOpenCodeAPI(
            sessions: [session("ses_root", updated: 1_700_000_001_000)]
        )
        let adapter = makeAdapter(endpoints: [], clients: ["desktop": api])
        let persisted = ProviderEndpoint(
            id: "desktop",
            provider: .openCode,
            origin: .desktop,
            baseURL: "http://127.0.0.1:41789",
            credentialReference: "keychain-ref",
            connected: true,
            version: "1.18.10",
            lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        try await adapter.restoreEndpoint(persisted)
        let snapshot = try await adapter.reconcile()

        XCTAssertTrue(snapshot.endpoints.isEmpty)
        XCTAssertTrue(snapshot.sessions.isEmpty)
    }

    /// An auto-discovered server that wants a password is a fact about the
    /// machine, not a task for the user: it reappears on every reconcile and
    /// cannot be dismissed. Only an endpoint the user attached themselves
    /// justifies an inbox prompt.
    func testDiscoveredEndpointNeedingAuthCreatesNoRequest() async throws {
        let adapter = makeAdapter(
            endpoints: [
                unauthenticated("desktop", origin: .desktop),
                unauthenticated("tui", origin: .tui),
            ],
            clients: [:]
        )

        let snapshot = try await adapter.reconcile()

        XCTAssertTrue(
            snapshot.requests.filter { $0.kind == .authentication }.isEmpty,
            "discovered endpoints must not raise an authentication request"
        )
        // The endpoint is still surfaced, just as not connected.
        XCTAssertEqual(snapshot.endpoints.count, 2)
        XCTAssertTrue(snapshot.endpoints.allSatisfy { !$0.connected })
    }

    func testManuallyAttachedEndpointNeedingAuthStillPrompts() async throws {
        let adapter = makeAdapter(
            endpoints: [unauthenticated("manual-1", origin: .manual)],
            clients: [:]
        )

        let snapshot = try await adapter.reconcile()

        let auth = snapshot.requests.filter { $0.kind == .authentication }
        XCTAssertEqual(auth.count, 1)
        XCTAssertEqual(auth.first?.threadID, "manual-1")
    }

    private func unauthenticated(
        _ id: String,
        origin: ProviderEndpointOrigin
    ) -> OpenCodeRuntimeEndpoint {
        var runtime = endpoint(id, origin: origin)
        runtime.summary.connected = false
        runtime.summary.message = "authenticationRequired"
        return runtime
    }

    private func makeAdapter(
        endpoints: [OpenCodeRuntimeEndpoint],
        clients: [String: any OpenCodeAPI],
        managedServer: (any ManagedOpenCodeServing)? = nil
    ) -> OpenCodeHybridAdapter {
        let clientMap = OpenCodeClientMap(clients)
        return OpenCodeHybridAdapter(
            accountID: "local-default",
            registry: OpenCodeEndpointRegistry(),
            managedServer: managedServer ?? FakeManagedOpenCodeServer(endpoint: endpoint("managed", origin: .managed)),
            discovery: FixedOpenCodeDiscovery(endpoints: endpoints),
            credentialStore: FixedCredentialStore(),
            clientFactory: { clientMap.client(for: $0.id) },
            now: { Date(timeIntervalSince1970: 1_700_000_010) }
        )
    }

    private func endpoint(
        _ id: String,
        origin: ProviderEndpointOrigin,
        applicationBundleID: String? = nil
    ) -> OpenCodeRuntimeEndpoint {
        OpenCodeRuntimeEndpoint(
            summary: ProviderEndpoint(
                id: id,
                provider: .openCode,
                origin: origin,
                baseURL: "http://127.0.0.1:\(41_700 + id.count)",
                connected: true,
                version: "1.18.10",
                lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            credential: .none,
            processID: 100,
            applicationBundleID: applicationBundleID
                ?? (origin == .desktop ? "ai.opencode.desktop" : nil),
            terminalTTY: origin == .tui ? "ttys001" : nil
        )
    }

    private func session(
        _ id: String,
        parentID: String? = nil,
        title: String = "Root",
        updated: Int64
    ) -> OpenCodeSession {
        OpenCodeSession(
            id: id,
            directory: "/tmp/repository",
            parentID: parentID,
            title: title,
            version: "1.18.10",
            time: .init(created: updated - 1_000, updated: updated)
        )
    }

    private func message(
        id: String,
        created: Int64,
        parts: [(String, String)]
    ) -> OpenCodeMessage {
        OpenCodeMessage(
            info: .init(
                id: id,
                sessionID: "ses_root",
                role: "assistant",
                time: .init(created: created, completed: created + 1)
            ),
            parts: parts.map {
                .init(id: $0.0, sessionID: "ses_root", messageID: id, type: "text", text: $0.1)
            }
        )
    }
}

private final class OpenCodeClientMap: @unchecked Sendable {
    private let clients: [String: any OpenCodeAPI]

    init(_ clients: [String: any OpenCodeAPI]) {
        self.clients = clients
    }

    func client(for endpointID: String) -> any OpenCodeAPI {
        clients[endpointID]!
    }
}

private struct FixedOpenCodeDiscovery: OpenCodeEndpointDiscovering {
    let endpoints: [OpenCodeRuntimeEndpoint]
    func discover() async throws -> [OpenCodeRuntimeEndpoint] { endpoints }
}

private struct FixedCredentialStore: CredentialStoring {
    func save(_ secret: String, reference: String) throws {}
    func read(reference: String) throws -> String { "secret" }
    func delete(reference: String) throws {}
}

private actor FakeManagedOpenCodeServer: ManagedOpenCodeServing {
    private let endpoint: OpenCodeRuntimeEndpoint
    private var count = 0

    init(endpoint: OpenCodeRuntimeEndpoint) {
        self.endpoint = endpoint
    }

    func ensureRunning() async throws -> OpenCodeRuntimeEndpoint {
        count += 1
        return endpoint
    }

    func stop() async {}
    func ensureCount() -> Int { count }
}

private actor FakeOpenCodeAPI: OpenCodeAPI {
    private var storedSessions: [OpenCodeSession]
    private let storedStatuses: [String: OpenCodeSessionStatus]
    private let storedMessages: [OpenCodeMessage]
    private let createdSession: OpenCodeSession?
    private let promptError: Error?
    private let permissionReplyError: OpenCodeHTTPError?
    private let selectSessionError: OpenCodeHTTPError?
    private var storedPermissions: [OpenCodePermissionRequest]
    private let storedQuestions: [OpenCodeQuestionRequest]
    private let eventStream: AsyncThrowingStream<OpenCodeEvent, Error>
    private let eventContinuation: AsyncThrowingStream<OpenCodeEvent, Error>.Continuation
    private var eventSubscriptions = 0
    private var creates = 0
    private var promptInputs: [AgentInput] = []
    private var requestedMessageLimits: [Int] = []
    private var permissionReplies: [(id: String, reply: OpenCodePermissionReply)] = []
    private var questionReplies: [(id: String, answers: [[String]])] = []
    private var selectedSessionIDs: [String] = []

    init(
        sessions: [OpenCodeSession],
        statuses: [String: OpenCodeSessionStatus] = [:],
        messages: [OpenCodeMessage] = [],
        createdSession: OpenCodeSession? = nil,
        promptError: Error? = nil,
        permissions: [OpenCodePermissionRequest] = [],
        questions: [OpenCodeQuestionRequest] = [],
        permissionReplyError: OpenCodeHTTPError? = nil,
        selectSessionError: OpenCodeHTTPError? = nil
    ) {
        storedSessions = sessions
        storedStatuses = statuses
        storedMessages = messages
        self.createdSession = createdSession
        self.promptError = promptError
        self.permissionReplyError = permissionReplyError
        self.selectSessionError = selectSessionError
        storedPermissions = permissions
        storedQuestions = questions
        let eventPair = AsyncThrowingStream<OpenCodeEvent, Error>.makeStream()
        eventStream = eventPair.stream
        eventContinuation = eventPair.continuation
    }

    func health() async throws -> OpenCodeHealth { .init(healthy: true, version: "1.18.10") }
    func sessions(directory: String?) async throws -> [OpenCodeSession] { storedSessions }

    func createSession(
        directory: String,
        title: String?,
        agent: String?,
        model: LaunchModelSelection?
    ) async throws -> OpenCodeSession {
        creates += 1
        let created = createdSession!
        storedSessions.append(created)
        return created
    }

    func session(id: String, directory: String?) async throws -> OpenCodeSession {
        storedSessions.first { $0.id == id }!
    }

    func deleteSession(id: String, directory: String?) async throws {}
    func statuses(directory: String?) async throws -> [String: OpenCodeSessionStatus] { storedStatuses }
    func children(sessionID: String, directory: String?) async throws -> [OpenCodeSession] {
        storedSessions.filter { $0.parentID == sessionID }
    }

    func messages(sessionID: String, directory: String?, limit: Int) async throws -> [OpenCodeMessage] {
        requestedMessageLimits.append(limit)
        return Array(storedMessages.prefix(limit))
    }

    func promptAsync(sessionID: String, directory: String, input: AgentInput) async throws {
        promptInputs.append(input)
        if let promptError { throw promptError }
    }

    func permissions(directory: String?) async throws -> [OpenCodePermissionRequest] {
        storedPermissions
    }
    func replyPermission(
        id: String,
        reply: OpenCodePermissionReply,
        message: String?,
        directory: String?
    ) async throws {
        if let permissionReplyError { throw permissionReplyError }
        permissionReplies.append((id, reply))
    }
    func questions(directory: String?) async throws -> [OpenCodeQuestionRequest] {
        storedQuestions
    }
    func replyQuestion(id: String, answers: [[String]], directory: String?) async throws {
        questionReplies.append((id, answers))
    }
    func events(directory: String?) async -> AsyncThrowingStream<OpenCodeEvent, Error> {
        eventSubscriptions += 1
        return eventStream
    }
    func selectSession(id: String, directory: String?) async throws {
        selectedSessionIDs.append(id)
        if let selectSessionError { throw selectSessionError }
    }

    func messageLimits() -> [Int] { requestedMessageLimits }
    func prompts() -> [AgentInput] { promptInputs }
    func createCount() -> Int { creates }
    func promptCount() -> Int { promptInputs.count }
    func recordedPermissionReplies() -> [(id: String, reply: OpenCodePermissionReply)] {
        permissionReplies
    }
    func recordedQuestionReplies() -> [(id: String, answers: [[String]])] {
        questionReplies
    }
    func setPermissions(_ permissions: [OpenCodePermissionRequest]) {
        storedPermissions = permissions
    }
    func emitEvent(_ event: OpenCodeEvent) {
        eventContinuation.yield(event)
    }
    func eventSubscriptionCount() -> Int { eventSubscriptions }
    func selectedSessions() -> [String] { selectedSessionIDs }
}
