import Foundation
import XCTest
import AgentHubCore
import AgentHubCursor
import AgentHubIPC
import AgentHubPersistence
import AgentHubTestSupport
@testable import AgentHubDaemon

final class CursorVerticalSliceTests: XCTestCase {
    func testCursorPermissionRoundTripThroughUnixSocket() async throws {
        let context = try await makeSocketContext()

        try await ingestSessionStart(through: context.client)
        let requestID = try await ingestShellPermission(through: context.client)

        async let awaited = context.client.send(
            .awaitHookPermission(requestID: requestID, timeoutMilliseconds: 5_000)
        )
        _ = try acceptedID(await context.client.send(.resolveRequest(requestID, .accept)))

        let permissionReply = try await awaited
        XCTAssertEqual(permissionReply, .hookPermission(.allow))

        let state = try await waitForSnapshot(context.client) { snapshot in
            snapshot.requests[requestID]?.state == .resolved
        }
        XCTAssertEqual(state.requests[requestID]?.provider, .cursor)
        XCTAssertEqual(state.requests[requestID]?.kind, .permission)

        await context.client.stop()
        await context.server.stop()
        await context.coordinator.stop()
        try? FileManager.default.removeItem(atPath: context.socketPath)
    }

    func testCursorPermissionDenyRoundTripThroughUnixSocket() async throws {
        let context = try await makeSocketContext()

        try await ingestSessionStart(through: context.client)
        let requestID = try await ingestShellPermission(through: context.client)

        async let awaited = context.client.send(
            .awaitHookPermission(requestID: requestID, timeoutMilliseconds: 5_000)
        )
        _ = try acceptedID(await context.client.send(.resolveRequest(requestID, .decline)))

        let permissionReply = try await awaited
        XCTAssertEqual(permissionReply, .hookPermission(.deny))

        await context.client.stop()
        await context.server.stop()
        await context.coordinator.stop()
        try? FileManager.default.removeItem(atPath: context.socketPath)
    }

    func testCursorPermissionAwaitTimesOutToAsk() async throws {
        let context = try await makeSocketContext()

        try await ingestSessionStart(through: context.client)
        let requestID = try await ingestShellPermission(through: context.client)

        let permissionReply = try await context.client.send(
            .awaitHookPermission(requestID: requestID, timeoutMilliseconds: 50)
        )
        XCTAssertEqual(permissionReply, .hookPermission(.ask))

        await context.client.stop()
        await context.server.stop()
        await context.coordinator.stop()
        try? FileManager.default.removeItem(atPath: context.socketPath)
    }

    func testCursorJumpTargetThroughUnixSocket() async throws {
        let context = try await makeSocketContext()
        try await ingestSessionStart(through: context.client)

        let snapshot = try await waitForSnapshot(context.client) { state in
            !state.sessions.isEmpty
        }
        let sessionID = try XCTUnwrap(snapshot.sessions.values.first?.id)

        let reply = try await context.client.send(.jumpTarget(sessionID))
        guard case .jump(let target) = reply else {
            return XCTFail("expected jump target reply")
        }
        guard case .application(let bundleID, let hint) = target else {
            return XCTFail("expected application jump target")
        }
        XCTAssertEqual(bundleID, CursorAdapter.cursorBundleID)
        XCTAssertEqual(hint, "/Users/example/repo")

        await context.client.stop()
        await context.server.stop()
        await context.coordinator.stop()
        try? FileManager.default.removeItem(atPath: context.socketPath)
    }

    func testCursorHandoffTargetIsClipboardAndJumpOnly() async throws {
        let store = try makeVerticalSliceStore()
        let adapter = CursorAdapter(accountID: "default")
        let adapters: [Provider: any AgentAdapter] = [.cursor: adapter]
        let handoffs = HandoffService(
            store: store,
            adapters: adapters,
            now: { Date(timeIntervalSince1970: 1_700_000_100) }
        )
        var envelope = MessageEnvelope.fixture()
        envelope.expiresAt = Date(timeIntervalSince1970: 1_700_000_300)
        let source = AgentSession.fixture()
        let target = cursorSession(
            id: envelope.targetSessionID,
            status: .idle
        )
        try await store.apply(.sessionUpserted(source))
        try await store.apply(.sessionUpserted(target))

        try await handoffs.submit(
            envelope,
            target: target,
            pendingRequests: []
        )

        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.envelopes[envelope.id]?.state, .manual)
        XCTAssertEqual(
            snapshot.envelopes[envelope.id]?.failure,
            "Target does not support managed input"
        )
    }

    // MARK: - Helpers

    private struct SocketContext {
        let socketPath: String
        let store: AgentHubStore
        let coordinator: Coordinator
        let server: UnixDaemonServer
        let client: UnixDaemonClient
    }

    private func makeVerticalSliceStore() throws -> AgentHubStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CursorVerticalSliceTests-\(UUID().uuidString)")
            .appendingPathComponent("agenthub.sqlite")
        return try AgentHubStore(databaseURL: url)
    }

    private func makeSocketContext() async throws -> SocketContext {
        let store = try makeVerticalSliceStore()
        let socketPath = "/tmp/ahc-\(UUID().uuidString.prefix(8)).sock"
        let adapter = CursorAdapter(
            accountID: "default",
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let adapters: [Provider: any AgentAdapter] = [.cursor: adapter]
        let coordinator = Coordinator(store: store, adapters: adapters)
        try await coordinator.start()
        let api = DaemonAPI(
            coordinator: coordinator,
            requests: RequestService(store: store, adapters: adapters),
            handoffs: HandoffService(store: store, adapters: adapters)
        )
        let server = try await UnixDaemonServer.bind(path: socketPath) { command in
            await api.handle(command)
        }
        let client = try await UnixDaemonClient.connect(path: socketPath)
        return SocketContext(
            socketPath: socketPath,
            store: store,
            coordinator: coordinator,
            server: server,
            client: client
        )
    }

    private func ingestSessionStart(through client: UnixDaemonClient) async throws {
        let reply = try await client.send(.ingestProviderHook(try hookEnvelope("session-start")))
        XCTAssertEqual(reply, .completed)
    }

    private func ingestShellPermission(through client: UnixDaemonClient) async throws -> UUID {
        let reply = try await client.send(
            .ingestProviderHook(try hookEnvelope("before-shell-execution"))
        )
        return try acceptedID(reply)
    }

    private func hookEnvelope(_ fixture: String) throws -> ProviderHookEnvelope {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Cursor/\(fixture).json")
        let data = try Data(contentsOf: url)
        return try ProviderHookEnvelope(
            provider: .cursor,
            rawJSON: data,
            sourcePID: 42,
            ancestors: [],
            observedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func cursorSession(
        id: UUID,
        status: SessionStatus
    ) -> AgentSession {
        AgentSession(
            id: id,
            providerRef: .fixture(provider: .cursor, nativeID: "conv-fixture-1"),
            title: "Cursor conv-fix",
            surface: "ide",
            ownership: .discovered,
            status: status,
            rootID: id,
            cwd: "/Users/example/repo",
            lastActivityAt: Date(timeIntervalSince1970: 1_700_000_000),
            capabilities: [
                .discover: .l2,
                .status: .l2,
                .children: .l2,
                .resolveRequest: .l2,
                .jump: .l3,
            ],
            preview: []
        )
    }

    private func acceptedID(_ reply: DaemonReply) throws -> UUID {
        guard case .accepted(let id) = reply else {
            throw VerticalSliceError.unexpectedReply(reply)
        }
        return id
    }

    private func waitForSnapshot(
        _ client: UnixDaemonClient,
        condition: (AgentHubState) -> Bool
    ) async throws -> AgentHubState {
        for _ in 0..<100 {
            guard case .snapshot(let state) = try await client.send(.getSnapshot) else {
                throw VerticalSliceError.snapshotUnavailable
            }
            if condition(state) { return state }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw VerticalSliceError.timedOut
    }
}

private enum VerticalSliceError: Error {
    case snapshotUnavailable
    case timedOut
    case unexpectedReply(DaemonReply)
}
