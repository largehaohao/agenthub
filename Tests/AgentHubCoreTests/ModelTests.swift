import Foundation
import XCTest
@testable import AgentHubCore
import AgentHubTestSupport

final class ModelTests: XCTestCase {
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
