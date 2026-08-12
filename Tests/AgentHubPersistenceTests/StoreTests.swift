import Foundation
import XCTest
import AgentHubCore
import AgentHubTestSupport
@testable import AgentHubPersistence

final class StoreTests: XCTestCase {
    func testRestartRestoresPendingAndQueuedState() async throws {
        let url = temporaryDatabaseURL()
        let first = try AgentHubStore(databaseURL: url)
        try await first.apply(.requestUpserted(.fixture(state: .pending)))
        try await first.apply(.envelopeUpserted(.fixture(state: .queued)))

        let restored = try await AgentHubStore(databaseURL: url).snapshot()

        XCTAssertEqual(restored.requests.values.first?.state, .pending)
        XCTAssertEqual(restored.envelopes.values.first?.state, .queued)
    }

    func testNamedQuotaWindowsPersistSideBySide() async throws {
        let url = temporaryDatabaseURL()
        let store = try AgentHubStore(databaseURL: url)
        let reset = Date(timeIntervalSince1970: 2_000)
        let fetched = Date(timeIntervalSince1970: 1_000)
        let session = try QuotaWindow(
            provider: .claude,
            accountID: "user@example.com",
            windowID: "session",
            label: "Session",
            plan: "Pro",
            usedPercent: 10,
            windowDuration: 18_000,
            resetsAt: reset,
            fetchedAt: fetched,
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
            fetchedAt: fetched,
            source: "codexbar"
        )

        try await store.apply(.quotaUpserted(session))
        try await store.apply(.quotaUpserted(sonnet))

        let restored = try await AgentHubStore(databaseURL: url).snapshot()
        XCTAssertEqual(restored.quotas.count, 2)
        XCTAssertEqual(restored.quotas[session.id], session)
        XCTAssertEqual(restored.quotas[sonnet.id], sonnet)
    }

    func testProviderComponentSurvivesRestart() async throws {
        let url = temporaryDatabaseURL()
        let store = try AgentHubStore(databaseURL: url)
        let component = ProviderComponentStatus(
            provider: .claude,
            component: "hooks",
            available: true,
            version: "2.1.228",
            path: "/tmp/hook",
            message: nil,
            changedAt: Date(timeIntervalSince1970: 1)
        )

        try await store.apply(.componentUpserted(component))

        let restored = try await AgentHubStore(databaseURL: url).snapshot()
        XCTAssertEqual(restored.components[component.id], component)
    }

    func testProviderComponentUpsertReplacesEarlierStatus() async throws {
        let url = temporaryDatabaseURL()
        let store = try AgentHubStore(databaseURL: url)
        let unavailable = ProviderComponentStatus(
            provider: .claude,
            component: "hooks",
            available: false,
            version: nil,
            path: nil,
            message: "not installed",
            changedAt: Date(timeIntervalSince1970: 1)
        )
        let available = ProviderComponentStatus(
            provider: .claude,
            component: "hooks",
            available: true,
            version: "2.1.228",
            path: "/tmp/hook",
            message: nil,
            changedAt: Date(timeIntervalSince1970: 2)
        )

        try await store.apply(.componentUpserted(unavailable))
        try await store.apply(.componentUpserted(available))

        let restored = try await AgentHubStore(databaseURL: url).snapshot()
        XCTAssertEqual(restored.components.count, 1)
        XCTAssertEqual(restored.components[available.id], available)
    }

    func testDuplicateProviderRequestCreatesOneRow() async throws {
        let store = try AgentHubStore(databaseURL: temporaryDatabaseURL())
        let first = PendingRequest.fixture(state: .pending)
        let duplicate = PendingRequest(
            id: UUID(),
            provider: first.provider,
            providerRequestID: first.providerRequestID,
            sessionID: first.sessionID,
            threadID: first.threadID,
            turnID: first.turnID,
            itemID: first.itemID,
            kind: first.kind,
            title: first.title,
            detail: first.detail,
            allowedActions: first.allowedActions,
            state: .resolving,
            reliability: first.reliability,
            createdAt: first.createdAt,
            expiresAt: first.expiresAt
        )

        try await store.apply(.requestUpserted(first))
        try await store.apply(.requestUpserted(duplicate))

        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.requests.count, 1)
        XCTAssertEqual(snapshot.requests.values.first?.id, duplicate.id)
        XCTAssertEqual(snapshot.requests.values.first?.state, .resolving)
    }

    func testLateSnapshotCannotReopenResolvedRequest() async throws {
        let store = try AgentHubStore(databaseURL: temporaryDatabaseURL())
        let request = PendingRequest.fixture(state: .pending)
        try await store.apply(.requestUpserted(request))
        try await store.apply(.requestResolutionStarted(id: request.id))
        try await store.apply(.requestResolved(id: request.id, outcome: "accepted"))

        try await store.apply(.requestUpserted(request))

        let restored = try await store.snapshot()
        XCTAssertEqual(restored.requests[request.id]?.state, .resolved)
    }

    func testSessionPreviewKeepsNewestThreeTurnsWithinByteLimit() async throws {
        let store = try AgentHubStore(databaseURL: temporaryDatabaseURL())
        var session = AgentSession.fixture()
        session.preview = (1...5).map {
            VisibleTurn(
                id: "turn-\($0)",
                role: "assistant",
                text: String(repeating: "x", count: 100_000),
                createdAt: Date(timeIntervalSince1970: TimeInterval($0))
            )
        }

        try await store.apply(.sessionUpserted(session))

        let restored = try await store.snapshot().sessions[session.id]
        XCTAssertEqual(restored?.preview.map(\.id), ["turn-4", "turn-5"])
        let encodedBytes = try restored?.preview.reduce(0) {
            $0 + (try JSONEncoder.agentHub.encode($1).count)
        }
        XCTAssertLessThanOrEqual(encodedBytes ?? .max, 256 * 1_024)
    }

    func testPrunePreviewCacheRemovesCompletedOutputAfterTwentyFourHours() async throws {
        let store = try AgentHubStore(databaseURL: temporaryDatabaseURL())
        var session = AgentSession.fixture(status: .completed)
        session.lastActivityAt = Date(timeIntervalSince1970: 1_000)
        try await store.apply(.sessionUpserted(session))

        try await store.prunePreviewCache(
            now: session.lastActivityAt.addingTimeInterval(24 * 60 * 60 + 1)
        )

        let restored = try await store.snapshot().sessions[session.id]
        XCTAssertEqual(restored?.preview, [])
    }

    func testDatabaseFileHasUserOnlyPermissions() throws {
        let url = temporaryDatabaseURL()
        _ = try AgentHubStore(databaseURL: url)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
    }

    func testManualEndpointPersistsOnlyReferenceAndCanBeRemoved() async throws {
        let url = temporaryDatabaseURL()
        let store = try AgentHubStore(databaseURL: url)
        let endpoint = ProviderEndpoint(
            id: "manual-1",
            provider: .openCode,
            origin: .manual,
            baseURL: "http://127.0.0.1:41789",
            credentialReference: "keychain-ref",
            connected: true,
            version: "1.18.10",
            lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        try await store.apply(.endpointUpserted(endpoint))

        var restored = try await AgentHubStore(databaseURL: url).snapshot()
        XCTAssertEqual(restored.endpoints[endpoint.id], endpoint)
        XCTAssertEqual(restored.endpoints[endpoint.id]?.credentialReference, "keychain-ref")

        try await store.apply(.endpointRemoved(endpoint.id))
        restored = try await AgentHubStore(databaseURL: url).snapshot()
        XCTAssertNil(restored.endpoints[endpoint.id])
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentHubStoreTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("agenthub.sqlite")
    }
}
