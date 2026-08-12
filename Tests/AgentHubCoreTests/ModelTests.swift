import Foundation
import XCTest
@testable import AgentHubCore
import AgentHubTestSupport

final class ModelTests: XCTestCase {
    func testProviderHookEnvelopeDecodingRejectsMoreThan256KiB() throws {
        let encoded = try JSONSerialization.data(withJSONObject: [
            "provider": "claude",
            "rawJSON": Data(
                repeating: 1,
                count: ProviderHookEnvelope.maximumPayloadBytes + 1
            ).base64EncodedString(),
            "sourcePID": 42,
            "ancestors": [],
            "observedAt": "1970-01-01T00:00:01Z",
        ])

        XCTAssertThrowsError(
            try JSONDecoder.agentHub.decode(ProviderHookEnvelope.self, from: encoded)
        ) { error in
            XCTAssertEqual(error as? ProviderHookEnvelopeError, .oversizedPayload)
        }
    }

    func testProviderHookEnvelopeRejectsMoreThan256KiB() {
        XCTAssertThrowsError(try ProviderHookEnvelope(
            provider: .claude,
            rawJSON: Data(repeating: 1, count: 256 * 1_024 + 1),
            sourcePID: 42,
            ancestors: [],
            observedAt: Date()
        )) { error in
            XCTAssertEqual(error as? ProviderHookEnvelopeError, .oversizedPayload)
        }
    }

    func testLaunchRequestDefaultsProviderOptionsToNil() {
        let request = LaunchRequest(
            clientRequestID: "request-1",
            cwd: "/tmp/repository",
            prompt: "Work on the task"
        )

        XCTAssertNil(request.agent)
        XCTAssertNil(request.model)
    }

    func testEndpointStateRoundTripsThroughCodable() throws {
        let endpoint = ProviderEndpoint(
            id: "openCode:manual:41789",
            provider: .openCode,
            origin: .manual,
            baseURL: "http://127.0.0.1:41789",
            credentialReference: "credential-reference",
            connected: true,
            version: "1.18.10",
            message: nil,
            lastSeenAt: Date(timeIntervalSince1970: 10)
        )
        let state = AgentHubState(endpoints: [endpoint.id: endpoint])

        let restored = try JSONDecoder.agentHub.decode(
            AgentHubState.self,
            from: JSONEncoder.agentHub.encode(state)
        )

        XCTAssertEqual(restored.endpoints[endpoint.id], endpoint)
    }

    func testPendingRequestWithoutFieldsDecodesWithEmptyFields() throws {
        let request = PendingRequest.fixture()
        let encoded = try JSONEncoder.agentHub.encode(request)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "fields")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let restored = try JSONDecoder.agentHub.decode(PendingRequest.self, from: legacy)

        XCTAssertEqual(restored.fields, [])
    }

    func testSessionRoundTripKeepsIdentity() throws {
        let session = AgentSession.fixture(status: .waitingPermission)
        let data = try JSONEncoder.agentHub.encode(session)

        XCTAssertEqual(
            try JSONDecoder.agentHub.decode(AgentSession.self, from: data),
            session
        )
    }

    func testQuotaRejectsOutOfRangePercent() {
        XCTAssertThrowsError(
            try QuotaWindow(
                provider: .codex,
                accountID: "personal",
                usedPercent: 101,
                windowDuration: 900,
                resetsAt: .now,
                fetchedAt: .now,
                source: "codex-app-server"
            )
        )
    }
}
