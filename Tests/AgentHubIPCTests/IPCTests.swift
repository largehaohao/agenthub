import Foundation
import XCTest
import AgentHubCore
import AgentHubTestSupport
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
        XCTAssertEqual(version, 3)

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
        XCTAssertThrowsError(try JSONLineCodec.validate(protocolVersion: 4)) {
            XCTAssertEqual($0 as? IPCError, .unsupportedProtocolVersion(4))
        }
    }

    func testProtocolV3RoundTripsBoundedClaudeHook() throws {
        let hook = try ProviderHookEnvelope(
            provider: .claude,
            rawJSON: Data("{\"hook_event_name\":\"SessionStart\"}".utf8),
            sourcePID: 42,
            ancestors: [],
            observedAt: Date(timeIntervalSince1970: 1)
        )

        let data = try JSONLineCodec.encode(
            IPCEnvelope(body: DaemonCommand.ingestProviderHook(hook))
        )
        let decoded = try JSONDecoder.agentHub.decode(
            IPCEnvelope<DaemonCommand>.self,
            from: data
        )

        XCTAssertEqual(decoded.protocolVersion, 3)
        guard case .ingestProviderHook(let restored) = decoded.body else {
            return XCTFail("hook command did not round trip")
        }
        XCTAssertEqual(restored, hook)
    }

    func testDecodeRejectsOversizedHookPayloadBypassingInitializer() throws {
        let oversized = Data(repeating: 0x41, count: ProviderHookEnvelope.maximumPayloadBytes + 1)
        let crafted: [String: Any] = [
            "protocolVersion": 3,
            "requestID": UUID().uuidString,
            "body": [
                "ingestProviderHook": [
                    "_0": [
                        "provider": "claude",
                        "rawJSON": oversized.base64EncodedString(),
                        "sourcePID": 42,
                        "ancestors": [],
                        "observedAt": 1,
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: crafted)

        XCTAssertThrowsError(
            try JSONDecoder.agentHub.decode(IPCEnvelope<DaemonCommand>.self, from: data)
        )
    }

    func testProviderConfigurationAndNativeInteractionCommandsRoundTrip() throws {
        let plan = NativeInteractionPlan(
            id: UUID(),
            provider: .claude,
            requestID: UUID(),
            bundleID: "com.anthropic.claudefordesktop",
            windowHint: nil,
            sessionNativeID: "abc123",
            promptFingerprint: "fingerprint",
            operation: .choose(label: "Yes")
        )
        let commands: [DaemonCommand] = [
            .configureProvider(.claude, .installHooks),
            .nativeInteractionStarted(requestID: plan.requestID, planID: plan.id),
        ]

        let decoded = try commands.map { command in
            let data = try JSONLineCodec.encode(IPCEnvelope(body: command))
            return try JSONDecoder.agentHub.decode(
                IPCEnvelope<DaemonCommand>.self,
                from: data
            )
        }

        XCTAssertTrue(decoded.allSatisfy { $0.protocolVersion == 3 })
        guard case .configureProvider(.claude, let action) = decoded[0].body else {
            return XCTFail("configure command did not round trip")
        }
        XCTAssertEqual(action, .installHooks)

        let replies: [DaemonReply] = [
            .components([
                ProviderComponentStatus(
                    provider: .claude,
                    component: "hooks",
                    available: true,
                    version: "2.1.228",
                    path: "/tmp/agenthub-claude-hook",
                    message: nil,
                    changedAt: Date(timeIntervalSince1970: 1)
                ),
            ]),
            .nativeInteraction(plan),
        ]
        for reply in replies {
            let data = try JSONEncoder.agentHub.encode(reply)
            XCTAssertEqual(try JSONDecoder.agentHub.decode(DaemonReply.self, from: data), reply)
        }
    }

    func testProtocolRoundTripsProviderAndEndpointCommands() throws {
        let attachment = ProviderEndpointAttachment(
            provider: .openCode,
            baseURL: "http://127.0.0.1:41789",
            credentialReference: "keychain-ref"
        )
        let binding = ProviderEndpointCredentialBinding(
            provider: .openCode,
            endpointID: "desktop-1",
            credentialReference: "keychain-ref"
        )
        let commands: [DaemonCommand] = [
            .launch(.openCode, .fixture()),
            .attachEndpoint(attachment),
            .authenticateEndpoint(binding),
            .detachEndpoint(provider: .openCode, id: "desktop-1"),
        ]

        let decoded = try commands.map { command in
            let data = try JSONLineCodec.encode(IPCEnvelope(body: command))
            return try JSONDecoder.agentHub.decode(
                IPCEnvelope<DaemonCommand>.self,
                from: data
            )
        }

        XCTAssertTrue(decoded.allSatisfy { $0.protocolVersion == 3 })
        guard case .launch(.openCode, let request) = decoded[0].body else {
            return XCTFail("launch command did not round trip")
        }
        XCTAssertEqual(request, .fixture())
        guard case .attachEndpoint(let restoredAttachment) = decoded[1].body else {
            return XCTFail("attachment command did not round trip")
        }
        XCTAssertEqual(restoredAttachment, attachment)
        guard case .authenticateEndpoint(let restoredBinding) = decoded[2].body else {
            return XCTFail("authentication command did not round trip")
        }
        XCTAssertEqual(restoredBinding, binding)
        guard case .detachEndpoint(.openCode, "desktop-1") = decoded[3].body else {
            return XCTFail("detach command did not round trip")
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
