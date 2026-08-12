import Foundation
import XCTest
import AgentHubCore
import AgentHubIPC
import AgentHubOpenCode
import AgentHubOpenCodeTestSupport
import AgentHubPersistence
import AgentHubSecurity
@testable import AgentHubDaemon

final class OpenCodeVerticalSliceTests: XCTestCase {
    func testMixedProviderLifecycleThroughUnixSocket() async throws {
        let tuiServer = try await FakeOpenCodeServer.start()
        let desktopServer = try await FakeOpenCodeServer.start()
        addTeardownBlock {
            await tuiServer.stop()
            await desktopServer.stop()
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentHubOpenCodeSlice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let shared = FakeOpenCodeServer.Session(
            id: "ses_shared",
            directory: directory.path,
            title: "Shared native OpenCode session"
        )
        await tuiServer.setSessions([shared])
        await desktopServer.setSessions([shared])

        let endpoints = [
            runtimeEndpoint(
                id: "a-tui",
                origin: .tui,
                baseURL: tuiServer.baseURL,
                bundleID: "com.googlecode.iterm2",
                tty: "ttys001"
            ),
            runtimeEndpoint(
                id: "b-desktop",
                origin: .desktop,
                baseURL: desktopServer.baseURL,
                bundleID: "ai.opencode.desktop"
            ),
        ]
        let managedEndpoint = runtimeEndpoint(
            id: "managed",
            origin: .managed,
            baseURL: tuiServer.baseURL
        )
        let codex = TestAdapter()
        let codexSource = makeCodexSource(directory: directory.path)
        await codex.setSnapshot(AdapterSnapshot(
            sessions: [codexSource],
            nodes: [],
            requests: [],
            quotas: []
        ))
        let openCode = makeOpenCodeAdapter(
            endpoints: endpoints,
            managedEndpoint: managedEndpoint
        )
        let databaseURL = directory.appendingPathComponent("agenthub.sqlite")
        let store = try AgentHubStore(databaseURL: databaseURL)
        let adapters: [Provider: any AgentAdapter] = [.codex: codex, .openCode: openCode]
        let coordinator = Coordinator(store: store, adapters: adapters)
        try await coordinator.start()
        let socketPath = "/tmp/ah-oc-\(UUID().uuidString.prefix(8)).sock"
        let api = DaemonAPI(
            coordinator: coordinator,
            requests: RequestService(store: store, adapters: adapters),
            handoffs: HandoffService(store: store, adapters: adapters)
        )
        let daemon = try await UnixDaemonServer.bind(path: socketPath) { command in
            await api.handle(command)
        }
        let client = try await UnixDaemonClient.connect(path: socketPath)

        var snapshot = try await readSnapshot(from: client)
        let sharedSessions = snapshot.sessions.values.filter {
            $0.providerRef.provider == .openCode && $0.providerRef.nativeID == "ses_shared"
        }
        XCTAssertEqual(sharedSessions.count, 1)
        let sharedSession = try XCTUnwrap(sharedSessions.first)

        let launchedID = try acceptedID(await client.send(.launch(.openCode, LaunchRequest(
            clientRequestID: "openCode-launch-1",
            cwd: directory.path,
            prompt: "Run the managed OpenCode task"
        ))))
        snapshot = try await readSnapshot(from: client)
        XCTAssertEqual(snapshot.sessions[launchedID]?.providerRef.provider, .openCode)

        try await waitUntil {
            await tuiServer.requests().contains { $0.path == "/event" }
        }
        await tuiServer.setPermissions([.init(
            id: "per_once",
            sessionID: "ses_shared",
            patterns: ["swift test"]
        )])
        await tuiServer.emitEvent(type: "permission.updated")
        snapshot = try await waitForSnapshot(client) { state in
            state.requests.values.contains { $0.providerRequestID == "per_once" }
        }
        let permission = try XCTUnwrap(snapshot.requests.values.first {
            $0.providerRequestID == "per_once"
        })
        _ = try acceptedID(await client.send(.resolveRequest(permission.id, .accept)))
        try await waitUntil { await tuiServer.permissionReplies()["per_once"] == "once" }

        await tuiServer.setPermissions([.init(id: "per_provider_first", sessionID: "ses_shared")])
        await tuiServer.emitEvent(type: "permission.updated")
        snapshot = try await waitForSnapshot(client) { state in
            state.requests.values.contains { $0.providerRequestID == "per_provider_first" }
        }
        let providerFirst = try XCTUnwrap(snapshot.requests.values.first {
            $0.providerRequestID == "per_provider_first"
        })
        await tuiServer.setPermissions([])
        await tuiServer.emitEvent(type: "permission.updated")
        snapshot = try await waitForSnapshot(client) { state in
            state.requests[providerFirst.id]?.state == .expired
        }
        XCTAssertEqual(snapshot.requests[providerFirst.id]?.state, .expired)

        await tuiServer.setQuestions([.init(
            id: "que_ordered",
            sessionID: "ses_shared",
            questions: [
                .init(
                    question: "Language",
                    header: "Language",
                    options: [.init(label: "Swift"), .init(label: "Rust")]
                ),
                .init(question: "Note", header: "Note", custom: true),
            ]
        )])
        await tuiServer.emitEvent(type: "question.updated")
        snapshot = try await waitForSnapshot(client) { state in
            state.requests.values.contains { $0.providerRequestID == "que_ordered" }
        }
        let question = try XCTUnwrap(snapshot.requests.values.first {
            $0.providerRequestID == "que_ordered"
        })
        _ = try acceptedID(await client.send(.resolveRequest(
            question.id,
            .answers([["Swift"], ["keep order"]])
        )))
        try await waitUntil {
            await tuiServer.questionReplies()["que_ordered"] == [["Swift"], ["keep order"]]
        }

        let handoffID = try acceptedID(await client.send(.createHandoff(
            source: codexSource.id,
            target: sharedSession.id,
            turnLimit: 3,
            note: "Continue in OpenCode"
        )))
        snapshot = try await waitForSnapshot(client) { state in
            state.envelopes[handoffID]?.state == .delivered
        }
        XCTAssertEqual(snapshot.envelopes[handoffID]?.state, .delivered)
        let handoffPrompts = await tuiServer.prompts().filter { $0.contains("AgentHub handoff") }
        XCTAssertEqual(handoffPrompts.count, 1)

        guard case .jump(.application(let bundleID, _)) = try await client.send(
            .jumpTarget(sharedSession.id)
        ) else {
            return XCTFail("expected native application jump")
        }
        XCTAssertEqual(bundleID, "com.googlecode.iterm2")
        let selectedSession = await tuiServer.selectedSessions().last
        XCTAssertEqual(selectedSession, "ses_shared")

        guard case .endpoint(let manualEndpoint) = try await client.send(.attachEndpoint(.init(
            provider: .openCode,
            baseURL: desktopServer.baseURL
        ))) else {
            return XCTFail("expected manual endpoint")
        }

        await client.stop()
        await daemon.stop()
        await coordinator.stop()
        await openCode.shutdown()

        let restartedOpenCode = makeOpenCodeAdapter(
            endpoints: endpoints,
            managedEndpoint: managedEndpoint
        )
        let restartedAdapters: [Provider: any AgentAdapter] = [
            .codex: codex,
            .openCode: restartedOpenCode,
        ]
        let restarted = Coordinator(store: store, adapters: restartedAdapters)
        try await restarted.start()
        let restartedState = await restarted.snapshot()
        XCTAssertNotNil(restartedState.sessions[sharedSession.id])
        XCTAssertNotNil(restartedState.envelopes[handoffID])
        XCTAssertEqual(restartedState.endpoints[manualEndpoint.id]?.origin, .manual)

        await tuiServer.setHealthy(false)
        await restarted.stop()
        await restartedOpenCode.shutdown()
        let isolatedOpenCode = makeOpenCodeAdapter(
            endpoints: endpoints,
            managedEndpoint: managedEndpoint
        )
        let isolatedAdapters: [Provider: any AgentAdapter] = [
            .codex: codex,
            .openCode: isolatedOpenCode,
        ]
        let isolated = Coordinator(store: store, adapters: isolatedAdapters)
        try await isolated.start()
        let isolatedState = await isolated.snapshot()
        XCTAssertEqual(isolatedState.adapterHealth[.codex]?.connected, true)
        XCTAssertEqual(isolatedState.adapterHealth[.openCode]?.connected, true)
        XCTAssertTrue(isolatedState.endpoints.values.contains {
            $0.baseURL == desktopServer.baseURL && $0.connected
        })

        await isolated.stop()
        await isolatedOpenCode.shutdown()
    }

    private func makeOpenCodeAdapter(
        endpoints: [OpenCodeRuntimeEndpoint],
        managedEndpoint: OpenCodeRuntimeEndpoint
    ) -> OpenCodeHybridAdapter {
        OpenCodeHybridAdapter(
            accountID: "acceptance",
            registry: OpenCodeEndpointRegistry(),
            managedServer: FixedManagedServer(endpoint: managedEndpoint),
            discovery: FixedDiscovery(endpoints: endpoints),
            credentialStore: NoopCredentialStore()
        )
    }

    private func runtimeEndpoint(
        id: String,
        origin: ProviderEndpointOrigin,
        baseURL: String,
        bundleID: String? = nil,
        tty: String? = nil
    ) -> OpenCodeRuntimeEndpoint {
        OpenCodeRuntimeEndpoint(
            summary: ProviderEndpoint(
                id: id,
                provider: .openCode,
                origin: origin,
                baseURL: baseURL,
                connected: true,
                version: "1.18.10",
                lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            credential: .none,
            processID: 42,
            applicationBundleID: bundleID,
            terminalTTY: tty
        )
    }

    private func makeCodexSource(directory: String) -> AgentSession {
        let id = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        return AgentSession(
            id: id,
            providerRef: .init(provider: .codex, accountID: "acceptance", nativeID: "codex-source"),
            title: "Codex source",
            surface: "Codex",
            ownership: .managed,
            status: .idle,
            rootID: id,
            cwd: directory,
            lastActivityAt: Date(timeIntervalSince1970: 1_700_000_000),
            capabilities: [.sendInput: .l1],
            preview: [.init(
                id: "turn-1",
                role: "assistant",
                text: "Use the verified result",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )]
        )
    }

    private func readSnapshot(from client: UnixDaemonClient) async throws -> AgentHubState {
        guard case .snapshot(let state) = try await client.send(.getSnapshot) else {
            throw VerticalSliceError.snapshotUnavailable
        }
        return state
    }

    private func waitForSnapshot(
        _ client: UnixDaemonClient,
        condition: (AgentHubState) -> Bool
    ) async throws -> AgentHubState {
        for _ in 0..<150 {
            let state = try await readSnapshot(from: client)
            if condition(state) { return state }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw VerticalSliceError.timedOut
    }

    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<150 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw VerticalSliceError.timedOut
    }

    private func acceptedID(_ reply: DaemonReply) throws -> UUID {
        guard case .accepted(let id) = reply else {
            throw VerticalSliceError.unexpectedReply(reply)
        }
        return id
    }
}

private struct FixedDiscovery: OpenCodeEndpointDiscovering {
    let endpoints: [OpenCodeRuntimeEndpoint]
    func discover() async throws -> [OpenCodeRuntimeEndpoint] { endpoints }
}

private actor FixedManagedServer: ManagedOpenCodeServing {
    let endpoint: OpenCodeRuntimeEndpoint
    init(endpoint: OpenCodeRuntimeEndpoint) { self.endpoint = endpoint }
    func ensureRunning() async throws -> OpenCodeRuntimeEndpoint { endpoint }
    func stop() async {}
}

private struct NoopCredentialStore: CredentialStoring {
    func save(_ secret: String, reference: String) throws {}
    func read(reference: String) throws -> String { "unused" }
    func delete(reference: String) throws {}
}

private enum VerticalSliceError: Error {
    case snapshotUnavailable
    case timedOut
    case unexpectedReply(DaemonReply)
}
