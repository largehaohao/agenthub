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

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentHubStoreTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("agenthub.sqlite")
    }
}
