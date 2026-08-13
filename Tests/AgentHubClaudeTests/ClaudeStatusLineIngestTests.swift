import Foundation
import XCTest
import AgentHubCore
@testable import AgentHubClaude

/// The status line arrives through the same envelope transport as hooks, so
/// these tests pin how the adapter tells the two apart.
final class ClaudeStatusLineIngestTests: XCTestCase {
    func testStatusLinePayloadBecomesQuotaWindows() async throws {
        let adapter = ClaudeAdapter(
            accountID: "personal",
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        try await adapter.ingest(statusLineEnvelope())

        let snapshot = try await adapter.reconcile()
        XCTAssertEqual(snapshot.quotas.map(\.windowID), ["five_hour", "seven_day"])
        XCTAssertEqual(snapshot.quotas.first?.usedPercent, 42.5)
        XCTAssertEqual(snapshot.quotas.first?.source, "claude-statusline")
    }

    func testStatusLinePayloadDoesNotCreateOrDisturbSessions() async throws {
        let adapter = ClaudeAdapter(
            accountID: "personal",
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        try await adapter.ingest(statusLineEnvelope())

        // A status line is a usage observation, not a session lifecycle event.
        let snapshot = try await adapter.reconcile()
        XCTAssertTrue(snapshot.sessions.isEmpty)
        XCTAssertTrue(snapshot.requests.isEmpty)
    }

    func testHookPayloadsStillCreateSessionsAndNoQuota() async throws {
        let adapter = ClaudeAdapter(
            accountID: "personal",
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        try await adapter.ingest(hookEnvelope())

        let snapshot = try await adapter.reconcile()
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertTrue(snapshot.quotas.isEmpty)
    }

    func testRepeatedStatusLinesReplaceRatherThanAccumulate() async throws {
        let adapter = ClaudeAdapter(
            accountID: "personal",
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        try await adapter.ingest(statusLineEnvelope())
        try await adapter.ingest(statusLineEnvelope(fiveHourPercent: 55))

        let snapshot = try await adapter.reconcile()
        XCTAssertEqual(snapshot.quotas.count, 2)
        XCTAssertEqual(snapshot.quotas.first?.usedPercent, 55)
    }

    func testStatusLineWithoutRateLimitsLeavesPreviousWindowsInPlace() async throws {
        let adapter = ClaudeAdapter(
            accountID: "personal",
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        try await adapter.ingest(statusLineEnvelope())

        try await adapter.ingest(try envelope(Data("""
        {"session_id":"abc123","context_window":{"used_percentage":1}}
        """.utf8)))

        // Losing the field must not blank a real reading the user already saw.
        let snapshot = try await adapter.reconcile()
        XCTAssertEqual(snapshot.quotas.count, 2)
    }

    /// Claude stops reporting `five_hour` once that window resets, while still
    /// sending `seven_day`. Replacing the whole set dropped the 5h row, and the
    /// daemon then pruned it from the strip entirely.
    func testPartialRateLimitsKeepUnreportedWindow() async throws {
        let adapter = ClaudeAdapter(
            accountID: "personal",
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        try await adapter.ingest(statusLineEnvelope())

        try await adapter.ingest(try envelope(Data("""
        {"session_id":"abc123","rate_limits":{
        "seven_day":{"used_percentage":43,
        "resets_at":"2026-08-17T00:00:00Z"}}}
        """.utf8)))

        let snapshot = try await adapter.reconcile()
        XCTAssertEqual(snapshot.quotas.count, 2, "5h window must survive")
        let byID = Dictionary(uniqueKeysWithValues: snapshot.quotas.map { ($0.windowID, $0) })
        XCTAssertEqual(byID["five_hour"]?.usedPercent, 42.5, "kept at its last real value")
        XCTAssertEqual(byID["seven_day"]?.usedPercent, 43, "updated to the new reading")
    }

    /// The usage cache is pollable, so reconcile picks it up even when no
    /// status line ever arrives.
    func testReconcileReadsUsageCacheWhenNoStatusLineSeen() async throws {
        let cache = try makeUsageCache(fiveHour: 33, fetchedAtMs: 1_786_532_498_571)
        let adapter = ClaudeAdapter(
            accountID: "personal",
            usageCacheReader: cache,
            now: { Date(timeIntervalSince1970: 1_786_532_600) }
        )

        let snapshot = try await adapter.reconcile()

        XCTAssertEqual(snapshot.quotas.count, 1)
        XCTAssertEqual(snapshot.quotas.first?.usedPercent, 33)
        XCTAssertEqual(snapshot.quotas.first?.source, "claude-usage-cache")
    }

    /// Both sources describe the same window; the newer observation wins so a
    /// fresh status line is not overwritten by an older cached number.
    func testNewerStatusLineWinsOverOlderCache() async throws {
        let cache = try makeUsageCache(fiveHour: 33, fetchedAtMs: 1_000_000)
        let adapter = ClaudeAdapter(
            accountID: "personal",
            usageCacheReader: cache,
            now: { Date(timeIntervalSince1970: 2_000) }
        )
        // observed_at is newer than the cache's fetchedAtMs.
        try await adapter.ingest(try envelope(Data("""
        {"session_id":"abc123","observed_at":9000000,
        "rate_limits":{"five_hour":{"used_percentage":77,
        "resets_at":"2026-08-12T14:50:00Z"}}}
        """.utf8)))

        let snapshot = try await adapter.reconcile()

        let fiveHour = snapshot.quotas.filter { $0.windowID == "five_hour" }
        XCTAssertEqual(fiveHour.count, 1, "one row per window, not one per source")
        XCTAssertEqual(fiveHour.first?.usedPercent, 77)
    }

    func testNewerCacheWinsOverOlderStatusLine() async throws {
        let cache = try makeUsageCache(fiveHour: 33, fetchedAtMs: 9_000_000_000)
        let adapter = ClaudeAdapter(
            accountID: "personal",
            usageCacheReader: cache,
            now: { Date(timeIntervalSince1970: 2_000) }
        )
        try await adapter.ingest(try envelope(Data("""
        {"session_id":"abc123","observed_at":1000,
        "rate_limits":{"five_hour":{"used_percentage":77,
        "resets_at":"2026-08-12T14:50:00Z"}}}
        """.utf8)))

        let snapshot = try await adapter.reconcile()

        let fiveHour = snapshot.quotas.filter { $0.windowID == "five_hour" }
        XCTAssertEqual(fiveHour.count, 1)
        XCTAssertEqual(fiveHour.first?.usedPercent, 33)
    }

    /// Anthropic sends `resets_at` with fractional seconds
    /// ("2026-08-12T14:50:00.458358+00:00"). A plain ISO8601 parser rejects
    /// those, and the window was then dropped without a trace, so Claude usage
    /// silently froze at whatever the usage cache last held.
    func testFractionalSecondResetTimesAreParsed() async throws {
        let adapter = ClaudeAdapter(
            accountID: "personal",
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        try await adapter.ingest(try envelope(Data("""
        {"session_id":"abc123","rate_limits":{
        "five_hour":{"used_percentage":11,
        "resets_at":"2026-08-14T14:50:00.458358+00:00"},
        "seven_day":{"used_percentage":22,
        "resets_at":"2026-08-17T01:00:00.458381+00:00"}}}
        """.utf8)))

        let snapshot = try await adapter.reconcile()
        XCTAssertEqual(snapshot.quotas.count, 2)
        XCTAssertEqual(snapshot.quotas.map(\.usedPercent).sorted(), [11, 22])
    }

    /// Timestamps without fractional seconds must keep working.
    func testWholeSecondResetTimesStillParse() async throws {
        let adapter = ClaudeAdapter(
            accountID: "personal",
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        try await adapter.ingest(try envelope(Data("""
        {"session_id":"abc123","rate_limits":{
        "five_hour":{"used_percentage":11,"resets_at":"2026-08-14T14:50:00Z"}}}
        """.utf8)))

        let snapshot = try await adapter.reconcile()
        XCTAssertEqual(snapshot.quotas.count, 1)
    }

    private func makeUsageCache(
        fiveHour: Double,
        fetchedAtMs: Double
    ) throws -> ClaudeUsageCacheReader {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agenthub-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(".claude.json")
        try Data("""
        {"cachedUsageUtilization":{"fetchedAtMs":\(Int(fetchedAtMs)),
        "utilization":{"five_hour":{"utilization":\(fiveHour),
        "resets_at":"2026-08-12T14:50:00.458358+00:00"}}}}
        """.utf8).write(to: url)
        return ClaudeUsageCacheReader(fileURL: url, accountID: "personal")
    }

    private func statusLineEnvelope(
        fiveHourPercent: Double = 42.5
    ) throws -> ProviderHookEnvelope {
        try envelope(Data("""
        {"session_id":"abc123","rate_limits":{
        "five_hour":{"used_percentage":\(fiveHourPercent),
        "resets_at":"2026-08-12T09:00:00Z"},
        "seven_day":{"used_percentage":12,
        "resets_at":"2026-08-17T00:00:00Z"}}}
        """.utf8))
    }

    private func hookEnvelope() throws -> ProviderHookEnvelope {
        try envelope(Data("""
        {"hook_event_name":"SessionStart","session_id":"abc123",
        "transcript_path":"/tmp/abc123.jsonl","cwd":"/tmp/repo"}
        """.utf8))
    }

    private func envelope(_ payload: Data) throws -> ProviderHookEnvelope {
        try ProviderHookEnvelope(
            provider: .claude,
            rawJSON: payload,
            sourcePID: 42,
            ancestors: [],
            observedAt: Date(timeIntervalSince1970: 1_000)
        )
    }
}
