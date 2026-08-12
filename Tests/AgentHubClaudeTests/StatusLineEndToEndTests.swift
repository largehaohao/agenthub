import Foundation
import XCTest
import AgentHubCore
@testable import AgentHubClaude

/// Proves the packaged reporter and the adapter agree on the wire format:
/// the bytes a real status line produces decode into real quota windows.
///
/// Runs by default because it uses only the fixture payload shape and touches
/// no real Claude state, no network, and no user settings.
final class StatusLineEndToEndTests: XCTestCase {
    func testPayloadFromDiskFlowsThroughEnvelopeIntoQuotaWindows() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Claude/statusline-payload.json")
        let payload = try Data(contentsOf: url)

        // Exactly what the reporter builds and sends over IPC.
        let envelope = try ProviderHookEnvelope(
            provider: .claude,
            rawJSON: payload,
            sourcePID: 42,
            ancestors: [],
            observedAt: Date(timeIntervalSince1970: 1_000)
        )
        let encoded = try JSONEncoder.agentHub.encode(envelope)
        let decoded = try JSONDecoder.agentHub.decode(ProviderHookEnvelope.self, from: encoded)

        let adapter = ClaudeAdapter(
            accountID: "personal",
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        try await adapter.ingest(decoded)

        let snapshot = try await adapter.reconcile()
        XCTAssertEqual(snapshot.quotas.map(\.windowID), ["five_hour", "seven_day"])
        XCTAssertEqual(snapshot.quotas.first?.usedPercent, 42.5)
        XCTAssertEqual(snapshot.quotas.first?.label, "Session")
    }

    /// The status line carries prompt-adjacent context; none of it may survive
    /// into persisted quota state.
    func testNoContextOrSessionDetailSurvivesIntoQuotaState() async throws {
        let payload = Data("""
        {"session_id":"abc","cwd":"/Users/me/secret-project",
        "transcript_path":"/Users/me/.claude/projects/x.jsonl",
        "context_window":{"total_input_tokens":42000},
        "rate_limits":{"five_hour":{"used_percentage":10,
        "resets_at":"2026-08-12T09:00:00Z"}}}
        """.utf8)
        let adapter = ClaudeAdapter(
            accountID: "personal",
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        try await adapter.ingest(try ProviderHookEnvelope(
            provider: .claude,
            rawJSON: payload,
            sourcePID: 42,
            ancestors: [],
            observedAt: Date(timeIntervalSince1970: 1_000)
        ))

        let quotas = try await adapter.reconcile().quotas
        let rendered = String(describing: quotas)
        XCTAssertFalse(rendered.contains("secret-project"))
        XCTAssertFalse(rendered.contains("x.jsonl"))
        XCTAssertFalse(rendered.contains("42000"))
    }
}
