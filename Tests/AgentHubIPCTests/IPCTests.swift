import Foundation
import XCTest
import AgentHubCore
@testable import AgentHubIPC

final class IPCTests: XCTestCase {
    func testSocketHasUserOnlyModeAndIsRemovedOnStop() async throws {
        let path = temporarySocketPath()
        let server = try await UnixDaemonServer.bind(path: path) { _ in
            .snapshot(.empty)
        }

        XCTAssertEqual(try fileMode(path) & 0o777, 0o600)
        await server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testSnapshotThenLiveEventNegotiatesVersion() async throws {
        let path = temporarySocketPath()
        let server = try await UnixDaemonServer.bind(path: path) { command in
            switch command {
            case .getSnapshot: .snapshot(.empty)
            default: .failure("unexpected command")
            }
        }
        defer { Task { await server.stop() } }
        let client = try await UnixDaemonClient.connect(path: path)
        defer { Task { await client.stop() } }

        let reply = try await client.send(.getSnapshot)
        XCTAssertEqual(reply, .snapshot(.empty))
        let version = await client.negotiatedProtocolVersion
        XCTAssertEqual(version, 1)

        var iterator = client.events.makeAsyncIterator()
        await server.broadcast(.stateChanged(sequence: 2))
        let event = await iterator.next()
        XCTAssertEqual(event, .stateChanged(sequence: 2))
    }

    func testReconnectScheduleUsesBoundedExponentialBackoff() {
        XCTAssertEqual(ReconnectSchedule.delays, [1, 2, 4, 8, 16, 32, 60])
    }

    func testClientReconnectsAfterServerRestart() async throws {
        let path = temporarySocketPath()
        let firstServer = try await snapshotServer(path: path)
        let client = try await UnixDaemonClient.connect(path: path)
        defer { Task { await client.stop() } }
        _ = try await client.send(.getSnapshot)

        await firstServer.stop()
        let secondServer = try await snapshotServer(path: path)
        defer { Task { await secondServer.stop() } }
        try await Task.sleep(for: .seconds(1.3))

        let reply = try await client.send(.getSnapshot)
        XCTAssertEqual(reply, .snapshot(.empty))
    }

    func testEncoderRejectsFramesOverOneMiB() throws {
        let command = DaemonCommand.sendInput(
            UUID(),
            AgentInput(text: String(repeating: "x", count: 1_024 * 1_024 + 1))
        )

        XCTAssertThrowsError(try JSONLineCodec.encode(IPCEnvelope(body: command))) {
            XCTAssertEqual($0 as? IPCError, .oversizedFrame)
        }
    }

    func testProtocolRejectsUnknownVersion() {
        XCTAssertThrowsError(try JSONLineCodec.validate(protocolVersion: 2)) {
            XCTAssertEqual($0 as? IPCError, .unsupportedProtocolVersion(2))
        }
    }

    private func temporarySocketPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("agenthub-\(UUID().uuidString).sock")
            .path
    }

    private func fileMode(_ path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }

    private func snapshotServer(path: String) async throws -> UnixDaemonServer {
        try await UnixDaemonServer.bind(path: path) { command in
            switch command {
            case .getSnapshot: .snapshot(.empty)
            default: .failure("unexpected command")
            }
        }
    }
}
