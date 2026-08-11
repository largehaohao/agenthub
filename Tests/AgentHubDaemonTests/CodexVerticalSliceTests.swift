import Foundation
import XCTest
import AgentHubCodex
import AgentHubCore
import AgentHubIPC
import AgentHubPersistence
@testable import AgentHubDaemon

final class CodexVerticalSliceTests: XCTestCase {
    func testLaunchApprovalHandoffQuotaAndRestartThroughUnixSocket() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentHubVerticalSlice-\(UUID().uuidString)")
        let databaseURL = directory.appendingPathComponent("agenthub.sqlite")
        let socketPath = "/tmp/ah-\(UUID().uuidString.prefix(8)).sock"
        let store = try AgentHubStore(databaseURL: databaseURL)
        let transport = ScriptedCodexTransport()
        let rpc = CodexRPCClient(transport: transport)
        try await rpc.start(clientName: "AgentHubAcceptanceTests", clientVersion: "0.1")
        let adapter = CodexAdapter(
            accountID: "acceptance",
            rpc: rpc,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let coordinator = Coordinator(store: store, adapters: [.codex: adapter])
        try await coordinator.start()
        let api = DaemonAPI(
            coordinator: coordinator,
            requests: RequestService(store: store, adapters: [.codex: adapter]),
            handoffs: HandoffService(store: store, adapters: [.codex: adapter])
        )
        let server = try await UnixDaemonServer.bind(path: socketPath) { command in
            await api.handle(command)
        }
        let client = try await UnixDaemonClient.connect(path: socketPath)

        let first = try acceptedID(await client.send(.launch(.codex, LaunchRequest(
            clientRequestID: "acceptance-1",
            cwd: directory.path,
            prompt: "Investigate the first task"
        ))))
        let second = try acceptedID(await client.send(.launch(.codex, LaunchRequest(
            clientRequestID: "acceptance-2",
            cwd: directory.path,
            prompt: "Continue the second task"
        ))))

        await transport.emitApproval(threadID: "thread-1", requestID: "approval-1")
        let pending = try await waitForSnapshot(client) { state in
            state.requests.values.contains { $0.providerRequestID == "approval-1" }
        }
        let request = try XCTUnwrap(pending.requests.values.first {
            $0.providerRequestID == "approval-1"
        })
        _ = try acceptedID(await client.send(.resolveRequest(request.id, .accept)))
        try await waitUntil { await transport.resolvedApproval("approval-1") == "accept" }

        let handoffID = try acceptedID(await client.send(.createHandoff(
            source: first,
            target: second,
            turnLimit: 5,
            note: "Use the useful context"
        )))
        let delivered = try await waitForSnapshot(client) { state in
            state.envelopes[handoffID]?.state == .delivered
        }

        XCTAssertEqual(delivered.sessions.count, 2)
        XCTAssertEqual(delivered.requests[request.id]?.state, .resolved)
        XCTAssertEqual(delivered.quotas.count, 2)
        XCTAssertEqual(delivered.envelopes[handoffID]?.state, .delivered)
        let sentHandoff = await transport.sentHandoff(to: "thread-2")
        XCTAssertTrue(sentHandoff)

        await client.stop()
        await server.stop()
        await coordinator.stop()

        let restartedCoordinator = Coordinator(store: store, adapters: [:])
        try await restartedCoordinator.start()
        let restartedAPI = DaemonAPI(
            coordinator: restartedCoordinator,
            requests: RequestService(store: store, adapters: [:]),
            handoffs: HandoffService(store: store, adapters: [:])
        )
        let restartedServer = try await UnixDaemonServer.bind(path: socketPath) { command in
            await restartedAPI.handle(command)
        }
        let restartedClient = try await UnixDaemonClient.connect(path: socketPath)
        guard case .snapshot(let restarted) = try await restartedClient.send(.getSnapshot) else {
            return XCTFail("Restarted daemon did not return a snapshot")
        }
        XCTAssertEqual(Set(restarted.sessions.keys), Set([first, second]))
        XCTAssertEqual(restarted.envelopes[handoffID]?.state, .delivered)

        await restartedClient.stop()
        await restartedServer.stop()
        await restartedCoordinator.stop()
        await rpc.stop()
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func acceptedID(_ reply: DaemonReply) throws -> UUID {
        guard case .accepted(let id) = reply else {
            throw AcceptanceError.unexpectedReply(reply)
        }
        return id
    }

    private func waitForSnapshot(
        _ client: UnixDaemonClient,
        condition: (AgentHubState) -> Bool
    ) async throws -> AgentHubState {
        for _ in 0..<100 {
            guard case .snapshot(let state) = try await client.send(.getSnapshot) else {
                throw AcceptanceError.snapshotUnavailable
            }
            if condition(state) { return state }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AcceptanceError.timedOut
    }

    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AcceptanceError.timedOut
    }
}

private enum AcceptanceError: Error {
    case snapshotUnavailable
    case timedOut
    case unexpectedReply(DaemonReply)
}

private actor ScriptedCodexTransport: LineTransport {
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var threads: [String: JSONValue] = [:]
    private var nextThread = 1
    private var approvalDecisions: [String: String] = [:]
    private var handoffTargets: Set<String> = []

    init() {
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func start() async throws {}

    func send(line: Data) async throws {
        let message = try decodeRPC(line)
        if let id = message.id, message.method == nil {
            let key = id.stringValue
            approvalDecisions[key] = message.result?["decision"]?.stringValue
            return
        }
        guard let method = message.method else { return }
        guard let id = message.id else { return }

        let result: JSONValue
        switch method {
        case "initialize":
            result = .object([:])
        case "thread/start":
            let nativeID = "thread-\(nextThread)"
            nextThread += 1
            threads[nativeID] = thread(id: nativeID, preview: "")
            result = .object(["thread": .object(["id": .string(nativeID)])])
        case "turn/start":
            guard let threadID = message.params?["threadId"]?.stringValue else {
                throw CodexRPCError.malformedMessage
            }
            let text = message.params?["input"]?.arrayValue?.first?["text"]?.stringValue ?? ""
            if text.hasPrefix("AgentHub handoff") { handoffTargets.insert(threadID) }
            if threads[threadID]?["preview"]?.stringValue?.isEmpty != false {
                threads[threadID] = thread(id: threadID, preview: text)
            }
            result = .object(["turn": .object(["id": .string("turn-\(threadID)")])])
        case "thread/list":
            result = .object(["data": .array(threads.keys.sorted().compactMap { threads[$0] })])
        case "account/rateLimits/read":
            result = .object(["rateLimits": .object([
                "primary": quota(used: 25, duration: 300, reset: 1_700_001_000),
                "secondary": quota(used: 40, duration: 10_080, reset: 1_700_100_000),
            ])])
        default:
            throw CodexRPCError.remote(code: -32601, message: "Unknown scripted method")
        }
        continuation.yield(try JSONEncoder().encode(JSONRPCMessage(id: id, result: result)))
    }

    func lines() async -> AsyncThrowingStream<Data, Error> { stream }
    func stop() async { continuation.finish() }

    func emitApproval(threadID: String, requestID: String) {
        let message = JSONRPCMessage(
            id: .string(requestID),
            method: "item/commandExecution/requestApproval",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string("turn-approval"),
                "itemId": .string("item-approval"),
                "reason": .string("Run acceptance checks"),
            ])
        )
        guard let encoded = try? JSONEncoder().encode(message) else { return }
        continuation.yield(encoded)
    }

    func resolvedApproval(_ id: String) -> String? { approvalDecisions[id] }
    func sentHandoff(to threadID: String) -> Bool { handoffTargets.contains(threadID) }

    private func thread(id: String, preview: String) -> JSONValue {
        .object([
            "id": .string(id),
            "sessionId": .string(id),
            "preview": .string(preview),
            "cwd": .string("/tmp/agenthub-acceptance"),
            "status": .object(["type": .string("idle")]),
            "updatedAt": .number(1_700_000_000),
        ])
    }

    private func quota(used: Double, duration: Double, reset: Double) -> JSONValue {
        .object([
            "usedPercent": .number(used),
            "windowDurationMins": .number(duration),
            "resetsAt": .number(reset),
        ])
    }
}

private extension JSONRPCID {
    var stringValue: String {
        switch self {
        case .integer(let value): String(value)
        case .string(let value): value
        }
    }
}
