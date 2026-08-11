import Foundation
import XCTest
import AgentHubCore
import AgentHubSecurity
@testable import AgentHubOpenCode

final class OpenCodeHybridAdapterTests: XCTestCase {
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
        origin: ProviderEndpointOrigin
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
            applicationBundleID: origin == .desktop ? "ai.opencode.desktop" : nil,
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
    private var creates = 0
    private var promptInputs: [AgentInput] = []
    private var requestedMessageLimits: [Int] = []

    init(
        sessions: [OpenCodeSession],
        statuses: [String: OpenCodeSessionStatus] = [:],
        messages: [OpenCodeMessage] = [],
        createdSession: OpenCodeSession? = nil,
        promptError: Error? = nil
    ) {
        storedSessions = sessions
        storedStatuses = statuses
        storedMessages = messages
        self.createdSession = createdSession
        self.promptError = promptError
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

    func permissions(directory: String?) async throws -> [OpenCodePermissionRequest] { [] }
    func replyPermission(
        id: String,
        reply: OpenCodePermissionReply,
        message: String?,
        directory: String?
    ) async throws {}
    func questions(directory: String?) async throws -> [OpenCodeQuestionRequest] { [] }
    func replyQuestion(id: String, answers: [[String]], directory: String?) async throws {}
    func events(directory: String?) async -> AsyncThrowingStream<OpenCodeEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func selectSession(id: String, directory: String?) async throws {}

    func messageLimits() -> [Int] { requestedMessageLimits }
    func prompts() -> [AgentInput] { promptInputs }
    func createCount() -> Int { creates }
    func promptCount() -> Int { promptInputs.count }
}
