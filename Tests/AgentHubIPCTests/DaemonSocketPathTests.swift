import Foundation
import XCTest
@testable import AgentHubIPC

final class DaemonSocketPathTests: XCTestCase {
    func testDaemonSocketPathHonorsAgentHubSocketOverride() throws {
        let path = try DaemonSocketPath.resolve(
            environment: ["AGENTHUB_SOCKET": "/tmp/agenthub-test.sock"]
        )
        XCTAssertEqual(path, "/tmp/agenthub-test.sock")
    }

    func testEmptyOverrideFallsBackRatherThanUsingAnEmptyPath() throws {
        let path = try DaemonSocketPath.resolve(environment: ["AGENTHUB_SOCKET": ""])
        XCTAssertTrue(path.hasSuffix("/AgentHub/agenthub.sock"))
    }

    func testAwaitHookPermissionCommandRoundTrips() throws {
        let id = UUID()
        let command = DaemonCommand.awaitHookPermission(
            requestID: id,
            timeoutMilliseconds: 25_000
        )
        let data = try JSONLineCodec.encode(IPCEnvelope(body: command))
        let decoded = try JSONDecoder.agentHub.decode(
            IPCEnvelope<DaemonCommand>.self,
            from: data
        )
        guard case .awaitHookPermission(let restoredID, 25_000) = decoded.body else {
            return XCTFail("awaitHookPermission did not round trip")
        }
        XCTAssertEqual(restoredID, id)

        let reply = DaemonReply.hookPermission(.ask)
        let replyData = try JSONEncoder.agentHub.encode(reply)
        XCTAssertEqual(
            try JSONDecoder.agentHub.decode(DaemonReply.self, from: replyData),
            reply
        )
    }
}
