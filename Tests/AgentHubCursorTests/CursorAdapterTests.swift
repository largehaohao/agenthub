import Foundation
import XCTest
import AgentHubCore
@testable import AgentHubCursor

final class CursorAdapterTests: XCTestCase {
    func testSessionStartCreatesIdeSessionKeyedByConversationID() async throws {
        let adapter = CursorAdapter(
            accountID: "default",
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        try await adapter.ingest(envelope(fixture: "session-start"))
        let snap = try await adapter.reconcile()
        XCTAssertEqual(snap.sessions.count, 1)
        let session = try XCTUnwrap(snap.sessions.first)
        XCTAssertEqual(session.providerRef.nativeID, "conv-fixture-1")
        XCTAssertEqual(session.surface, "ide")
        XCTAssertEqual(session.ownership, .discovered)
        XCTAssertEqual(session.status, .idle)
    }

    func testBeforeShellExecutionCreatesPendingPermissionRequest() async throws {
        let adapter = CursorAdapter(accountID: "default")
        try await adapter.ingest(envelope(fixture: "session-start"))
        try await adapter.ingest(envelope(fixture: "before-shell-execution"))
        let snap = try await adapter.reconcile()
        XCTAssertEqual(snap.requests.count, 1)
        let request = try XCTUnwrap(snap.requests.first)
        XCTAssertEqual(request.provider, .cursor)
        XCTAssertEqual(request.kind, .permission)
        XCTAssertEqual(request.title, "Shell permission")
        let status = try XCTUnwrap(snap.sessions.first?.status)
        XCTAssertEqual(status, .waitingPermission)
        let lastID = await adapter.lastPermissionRequestID
        XCTAssertEqual(lastID, request.id)
    }

    func testLaunchIsUnsupported() async {
        let adapter = CursorAdapter(accountID: "default")
        do {
            _ = try await adapter.launch(
                LaunchRequest(
                    clientRequestID: "x",
                    cwd: "/tmp",
                    prompt: "hi"
                )
            )
            XCTFail("launch should be unsupported")
        } catch {
            XCTAssertEqual(error as? CursorAdapterError, .unsupportedCapability)
        }
    }

    func testJumpUsesCursorBundleAndWorkspaceHint() async throws {
        let adapter = CursorAdapter(accountID: "default")
        try await adapter.ingest(envelope(fixture: "session-start"))
        let snap = try await adapter.reconcile()
        let session = try XCTUnwrap(snap.sessions.first)
        let target = await adapter.jumpTarget(for: session.providerRef)
        guard case .application(let bundleID, let hint) = target else {
            return XCTFail("expected application jump")
        }
        XCTAssertEqual(bundleID, CursorAdapter.cursorBundleID)
        XCTAssertEqual(hint, "/Users/example/repo")
    }

    func testSubagentStartCreatesNode() async throws {
        let adapter = CursorAdapter(accountID: "default")
        try await adapter.ingest(envelope(fixture: "session-start"))
        try await adapter.ingest(envelope(fixture: "subagent-start"))
        let snap = try await adapter.reconcile()
        XCTAssertEqual(snap.nodes.count, 1)
        XCTAssertEqual(snap.nodes.first?.nativeID, "sub-1")
    }

    private func envelope(fixture name: String) throws -> ProviderHookEnvelope {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Cursor/\(name).json")
        let data = try Data(contentsOf: url)
        return try ProviderHookEnvelope(
            provider: .cursor,
            rawJSON: data,
            sourcePID: 42,
            ancestors: [],
            observedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
