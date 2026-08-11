import Foundation
import XCTest
@testable import AgentHubCodex

final class CodexRPCClientTests: XCTestCase {
    func testOutOfOrderResponsesResumeCorrectCallers() async throws {
        let transport = ScriptedLineTransport()
        let client = CodexRPCClient(transport: transport)

        let firstTask = Task {
            try await client.call(
                method: "thread/read",
                params: .object(["threadId": .string("a")])
            )
        }
        await transport.waitForSentCount(1)
        let firstID = try await transport.sentMessage(at: 0).requiredID

        let secondTask = Task {
            try await client.call(method: "account/rateLimits/read", params: nil)
        }
        await transport.waitForSentCount(2)
        let secondID = try await transport.sentMessage(at: 1).requiredID

        await transport.receive(response(id: secondID, result: .object(["rateLimits": .null])))
        await transport.receive(response(id: firstID, result: .object([
            "thread": .object(["id": .string("a")]),
        ])))

        let first = try await firstTask.value
        let second = try await secondTask.value
        XCTAssertEqual(first["thread"]?["id"], .string("a"))
        XCTAssertEqual(second["rateLimits"], .null)
    }

    func testApprovalLineIsServerRequest() throws {
        let message = try decodeRPC(
            #"{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"t"}}"#
        )

        XCTAssertTrue(message.isServerRequest)
        XCTAssertEqual(message.id, .string("approval-1"))
    }

    func testServerRequestIsPublishedToMessageStream() async throws {
        let transport = ScriptedLineTransport()
        let client = CodexRPCClient(transport: transport)
        let messages = await client.messages()
        var iterator = messages.makeAsyncIterator()

        await transport.receive(Data(
            #"{"id":"approval-2","method":"item/commandExecution/requestApproval","params":{"threadId":"t"}}"#.utf8
        ))

        let message = await iterator.next()
        XCTAssertEqual(message?.id, .string("approval-2"))
        XCTAssertTrue(message?.isServerRequest == true)
        await client.stop()
    }

    func testStartPerformsInitializeHandshake() async throws {
        let transport = ScriptedLineTransport()
        let client = CodexRPCClient(transport: transport)
        let start = Task {
            try await client.start(clientName: "AgentHub", clientVersion: "0.1")
        }

        await transport.waitForSentCount(1)
        let initialize = try await transport.sentMessage(at: 0)
        XCTAssertEqual(initialize.method, "initialize")
        await transport.receive(response(id: try initialize.requiredID, result: .object([:])))
        try await start.value

        await transport.waitForSentCount(2)
        let initialized = try await transport.sentMessage(at: 1)
        XCTAssertEqual(initialized.method, "initialized")
        XCTAssertNil(initialized.id)
    }

    func testMalformedFrameFailsPendingCallOnce() async throws {
        let transport = ScriptedLineTransport()
        let client = CodexRPCClient(transport: transport)
        let call = Task { try await client.call(method: "thread/list", params: nil) }
        await transport.waitForSentCount(1)

        await transport.receive(Data("{".utf8))

        do {
            _ = try await call.value
            XCTFail("malformed frame did not fail the call")
        } catch {
            XCTAssertEqual(error as? CodexRPCError, .malformedMessage)
        }
    }

    func testEOFFailsPendingCall() async throws {
        let transport = ScriptedLineTransport()
        let client = CodexRPCClient(transport: transport)
        let call = Task { try await client.call(method: "thread/list", params: nil) }
        await transport.waitForSentCount(1)

        await transport.finish()

        do {
            _ = try await call.value
            XCTFail("EOF did not fail the call")
        } catch {
            XCTAssertEqual(error as? CodexRPCError, .transportEnded)
        }
    }

    func testTimedOutCallFailsWithoutTerminatingClient() async throws {
        let transport = ScriptedLineTransport()
        let client = CodexRPCClient(transport: transport)

        do {
            _ = try await client.call(
                method: "account/rateLimits/read",
                params: nil,
                timeout: .milliseconds(20)
            )
            XCTFail("call did not time out")
        } catch {
            XCTAssertEqual(error as? CodexRPCError, .timedOut)
        }

        let next = Task { try await client.call(method: "thread/list", params: nil) }
        await transport.waitForSentCount(2)
        let nextID = try await transport.sentMessage(at: 1).requiredID
        await transport.receive(response(id: nextID, result: .object(["data": .array([])])))

        let result = try await next.value
        XCTAssertEqual(result["data"], .array([]))
    }

    func testDiagnosticsRedactCredentials() {
        let input = #"Authorization: Bearer secret-token sk-live123 {"api_key":"private"}"#
        let redacted = CodexProcess.redact(input)

        XCTAssertFalse(redacted.contains("secret-token"))
        XCTAssertFalse(redacted.contains("sk-live123"))
        XCTAssertFalse(redacted.contains("private"))
    }

    func testInstalledCodexProcessCompletesHandshake() async throws {
        let client = CodexRPCClient(transport: CodexProcess())
        do {
            try await client.start(clientName: "AgentHubTests", clientVersion: "0.1")
        } catch CodexRPCError.executableNotFound {
            throw XCTSkip("Codex CLI is not installed")
        }
        await client.stop()
    }

    private func response(id: JSONRPCID, result: JSONValue) -> Data {
        try! JSONEncoder().encode(JSONRPCMessage(id: id, result: result))
    }
}

private actor ScriptedLineTransport: LineTransport {
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var sent: [Data] = []

    init() {
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func start() async throws {}

    func send(line: Data) async throws {
        sent.append(line)
    }

    func lines() async -> AsyncThrowingStream<Data, Error> {
        stream
    }

    func stop() async {
        continuation.finish()
    }

    func receive(_ line: Data) {
        continuation.yield(line)
    }

    func finish() {
        continuation.finish()
    }

    func waitForSentCount(_ count: Int) async {
        while sent.count < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func sentMessage(at index: Int) throws -> JSONRPCMessage {
        try decodeRPC(sent[index])
    }
}

private extension JSONRPCMessage {
    var requiredID: JSONRPCID {
        get throws {
            guard let id else { throw CodexRPCError.malformedMessage }
            return id
        }
    }
}
