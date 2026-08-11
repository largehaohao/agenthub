import Foundation
import XCTest
import AgentHubCore
@testable import AgentHubCodex

final class CodexAdapterTests: XCTestCase {
    func testWaitingApprovalMapsToNormalizedStatus() async throws {
        let adapter = try makeAdapter(threadFixture: "thread-status")
        let snapshot = try await adapter.reconcile()

        XCTAssertEqual(snapshot.sessions.first?.status, .waitingPermission)
    }

    func testSpawnedThreadUsesExplicitParent() async throws {
        let adapter = try makeAdapter(threadFixture: "subagent-tree")
        let snapshot = try await adapter.reconcile()

        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.nodes.first?.nativeID, "child-thread")
        XCTAssertEqual(snapshot.nodes.first?.parentNativeID, "root-thread")
    }

    func testRateLimitProducesTwoWindows() async throws {
        let result = try fixture(named: "rate-limits")
        let transport = MethodResponseTransport(responses: ["account/rateLimits/read": result])
        let adapter = CodexAdapter(
            accountID: "personal",
            rpc: CodexRPCClient(transport: transport),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let windows = try await adapter.quotaWindows()

        XCTAssertEqual(windows.count, 2)
        XCTAssertTrue(windows.allSatisfy { $0.source == "codex-app-server" })
        XCTAssertEqual(windows.map(\.usedPercent).sorted(), [25, 40])
    }

    func testRecentTurnsAreClampedToTwenty() async throws {
        let turns: [JSONValue] = (1...25).map {
            .object([
                "id": .string("turn-\($0)"),
                "summary": .string("result \($0)"),
                "createdAt": .number(Double($0)),
            ])
        }
        let transport = MethodResponseTransport(responses: [
            "thread/turns/list": .object(["data": .array(turns)]),
        ])
        let adapter = CodexAdapter(accountID: "personal", rpc: CodexRPCClient(transport: transport))

        let result = try await adapter.recentTurns(
            for: ProviderSessionRef(provider: .codex, accountID: "personal", nativeID: "root"),
            limit: 100
        )

        XCTAssertEqual(result.count, 20)
    }

    func testApprovalRequestIsPublishedAsPendingRequest() async throws {
        let transport = MethodResponseTransport(responses: [:])
        let adapter = CodexAdapter(accountID: "personal", rpc: CodexRPCClient(transport: transport))
        let events = await adapter.eventStream()
        var iterator = events.makeAsyncIterator()

        await transport.receive(Data(
            #"{"id":"approval-7","method":"item/commandExecution/requestApproval","params":{"threadId":"root-thread","turnId":"turn-1","itemId":"item-1","reason":"Run tests"}}"#.utf8
        ))

        guard case .requestUpserted(let request) = await iterator.next() else {
            return XCTFail("missing request event")
        }
        XCTAssertEqual(request.providerRequestID, "approval-7")
        XCTAssertEqual(request.state, .pending)
        XCTAssertEqual(request.kind, .permission)
    }

    private func makeAdapter(threadFixture: String) throws -> CodexAdapter {
        let result = try fixture(named: threadFixture)
        let transport = MethodResponseTransport(responses: ["thread/list": result])
        return CodexAdapter(
            accountID: "personal",
            rpc: CodexRPCClient(transport: transport),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    private func fixture(named name: String) throws -> JSONValue {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Codex/\(name).jsonl")
        return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }
}

private actor MethodResponseTransport: LineTransport {
    private let responses: [String: JSONValue]
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init(responses: [String: JSONValue]) {
        self.responses = responses
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func start() async throws {}

    func send(line: Data) async throws {
        let request = try decodeRPC(line)
        guard let id = request.id, let method = request.method,
              let result = responses[method] else {
            throw CodexRPCError.malformedMessage
        }
        continuation.yield(try JSONEncoder().encode(JSONRPCMessage(id: id, result: result)))
    }

    func lines() async -> AsyncThrowingStream<Data, Error> { stream }
    func stop() async { continuation.finish() }

    func receive(_ line: Data) {
        continuation.yield(line)
    }
}
