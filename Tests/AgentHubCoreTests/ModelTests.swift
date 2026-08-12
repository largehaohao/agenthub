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

    func testNamedQuotaWindowsWithSameDurationHaveDistinctIDs() throws {
        let reset = Date(timeIntervalSince1970: 2_000)
        let now = Date(timeIntervalSince1970: 1_000)
        let overall = try QuotaWindow(
            provider: .claude,
            accountID: "user@example.com",
            windowID: "session",
            label: "Session",
            plan: "Pro",
            usedPercent: 10,
            windowDuration: 18_000,
            resetsAt: reset,
            fetchedAt: now,
            source: "codexbar"
        )
        let sonnet = try QuotaWindow(
            provider: .claude,
            accountID: "user@example.com",
            windowID: "sonnet",
            label: "Sonnet",
            plan: "Pro",
            usedPercent: 20,
            windowDuration: 18_000,
            resetsAt: reset,
            fetchedAt: now,
            source: "codexbar"
        )

        XCTAssertNotEqual(overall.id, sonnet.id)
        XCTAssertEqual(overall.windowID, "session")
        XCTAssertEqual(overall.label, "Session")
        XCTAssertEqual(overall.plan, "Pro")
    }

    func testUnnamedQuotaWindowKeepsLegacyIdentity() throws {
        let window = try QuotaWindow(
            provider: .codex,
            accountID: "personal",
            usedPercent: 10,
            windowDuration: 900,
            resetsAt: .now,
            fetchedAt: .now,
            source: "codex-app-server"
        )

        XCTAssertEqual(window.id, "codex:personal:900")
        XCTAssertNil(window.windowID)
        XCTAssertNil(window.label)
        XCTAssertNil(window.plan)
    }

    func testQuotaWindowDecodesRowsWrittenBeforeLabelsExisted() throws {
        let legacy = Data("""
        {
          "id": "codex:personal:900",
          "provider": "codex",
          "accountID": "personal",
          "usedPercent": 12.5,
          "windowDuration": 900,
          "resetsAt": "1970-01-01T00:16:40Z",
          "fetchedAt": "1970-01-01T00:15:00Z",
          "source": "codex-app-server"
        }
        """.utf8)

        let decoded = try JSONDecoder.agentHub.decode(QuotaWindow.self, from: legacy)

        XCTAssertEqual(decoded.id, "codex:personal:900")
        XCTAssertEqual(decoded.usedPercent, 12.5)
        XCTAssertNil(decoded.windowID)
        XCTAssertNil(decoded.label)
        XCTAssertNil(decoded.plan)
    }

    func testLabeledQuotaWindowRoundTripsThroughCoding() throws {
        let window = try QuotaWindow(
            provider: .claude,
            accountID: "user@example.com",
            windowID: "weekly",
            label: "Weekly",
            plan: "Pro",
            usedPercent: 40,
            windowDuration: 604_800,
            resetsAt: Date(timeIntervalSince1970: 5_000),
            fetchedAt: Date(timeIntervalSince1970: 1_000),
            source: "codexbar"
        )

        let data = try JSONEncoder.agentHub.encode(window)
        XCTAssertEqual(try JSONDecoder.agentHub.decode(QuotaWindow.self, from: data), window)
    }
}
