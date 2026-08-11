import Foundation
import XCTest
@testable import AgentHubCodex

final class LiveCodexTests: XCTestCase {
    func testOptInThreadRoundTripAndQuotaRead() async throws {
        guard ProcessInfo.processInfo.environment["AGENTHUB_RUN_LIVE_CODEX_TESTS"] == "1" else {
            throw XCTSkip("Set AGENTHUB_RUN_LIVE_CODEX_TESTS=1 to create an archived live Codex thread")
        }

        let rpc = CodexRPCClient(transport: CodexProcess())
        try await rpc.start(clientName: "AgentHubLiveTests", clientVersion: "0.1")
        var threadID: String?
        do {
            let started = try await rpc.call(
                method: "thread/start",
                params: .object([
                    "cwd": .string(FileManager.default.temporaryDirectory.path),
                    "approvalPolicy": .string("never"),
                    "sandbox": .string("read-only"),
                ])
            )
            threadID = started["thread"]?["id"]?.stringValue
            let id = try XCTUnwrap(threadID)

            _ = try await rpc.call(
                method: "turn/start",
                params: .object([
                    "threadId": .string(id),
                    "input": .array([.object([
                        "type": .string("text"),
                        "text": .string("Reply with the single word READY and do not use tools"),
                    ])]),
                ])
            )

            var assistantText: String?
            for _ in 0..<120 {
                let read = try await rpc.call(
                    method: "thread/read",
                    params: .object([
                        "threadId": .string(id),
                        "includeTurns": .bool(true),
                    ])
                )
                assistantText = agentMessage(in: read["thread"])
                let idle = read["thread"]?["status"]?["type"]?.stringValue == "idle"
                if idle, assistantText != nil { break }
                try await Task.sleep(for: .milliseconds(500))
            }
            XCTAssertEqual(assistantText?.trimmingCharacters(in: .whitespacesAndNewlines), "READY")

            let quota = try await rpc.call(method: "account/rateLimits/read", params: nil)
            XCTAssertNotNil(quota["rateLimits"])

            _ = try await rpc.call(
                method: "thread/archive",
                params: .object(["threadId": .string(id)])
            )
            threadID = nil
            await rpc.stop()
        } catch {
            if let threadID {
                _ = try? await rpc.call(
                    method: "thread/archive",
                    params: .object(["threadId": .string(threadID)])
                )
            }
            await rpc.stop()
            throw error
        }
    }

    private func agentMessage(in thread: JSONValue?) -> String? {
        for turn in thread?["turns"]?.arrayValue ?? [] {
            for item in turn["items"]?.arrayValue ?? []
            where item["type"]?.stringValue == "agentMessage" {
                if let text = item["text"]?.stringValue { return text }
            }
        }
        return nil
    }
}
