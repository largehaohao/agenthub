import Foundation
import XCTest
import AgentHubCore
@testable import AgentHubClaude

final class ClaudeQuotaRefreshTests: XCTestCase {
    func testRefreshScheduleUsesBoundedBackoffAndFiveMinuteSuccessInterval() {
        XCTAssertEqual(ClaudeQuotaRefreshSchedule.failureDelays, [60, 120, 240, 480, 900])
        XCTAssertEqual(ClaudeQuotaRefreshSchedule.successInterval, 300)
    }

    func testBackoffAdvancesThenResetsAfterOneValidSnapshot() {
        var schedule = ClaudeQuotaRefreshSchedule()
        XCTAssertEqual(schedule.nextDelay(afterFailure: true), 60)
        XCTAssertEqual(schedule.nextDelay(afterFailure: true), 120)
        XCTAssertEqual(schedule.nextDelay(afterFailure: true), 240)
        XCTAssertEqual(schedule.nextDelay(afterFailure: false), 300)
        // One good snapshot returns the loop to the normal cadence.
        XCTAssertEqual(schedule.nextDelay(afterFailure: true), 60)
    }

    func testBackoffSaturatesAtLongestDelay() {
        var schedule = ClaudeQuotaRefreshSchedule()
        for _ in 0..<10 { _ = schedule.nextDelay(afterFailure: true) }
        XCTAssertEqual(schedule.nextDelay(afterFailure: true), 900)
    }

    func testSuccessfulRefreshPublishesWindowsAndHealthyComponent() async throws {
        let window = try QuotaWindow(
            provider: .claude,
            accountID: "user@example.com",
            windowID: "session",
            label: "Session",
            plan: "Pro",
            usedPercent: 10,
            windowDuration: 18_000,
            resetsAt: Date(timeIntervalSince1970: 20_000),
            fetchedAt: Date(timeIntervalSince1970: 1_000),
            source: "codexbar"
        )
        let collector = StubQuotaCollector(result: .success(.init(
            executablePath: "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI",
            windows: [window],
            isPartial: false
        )))
        let adapter = ClaudeAdapter(
            accountID: "personal",
            quotaCollector: collector,
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        try await adapter.refreshQuota()

        let snapshot = try await adapter.reconcile()
        XCTAssertEqual(snapshot.quotas, [window])
        let codexbar = await adapter.componentStatus(named: "codexbar")
        let component = try XCTUnwrap(codexbar)
        XCTAssertTrue(component.available)
        XCTAssertEqual(
            component.path,
            "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI"
        )
    }

    func testMissingCodexBarIsReportedUnavailableWithoutThrowing() async throws {
        let collector = StubQuotaCollector(result: .failure(.sourceUnavailable))
        let adapter = ClaudeAdapter(
            accountID: "personal",
            quotaCollector: collector,
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        try await adapter.refreshQuota()

        let codexbar = await adapter.componentStatus(named: "codexbar")
        let component = try XCTUnwrap(codexbar)
        XCTAssertFalse(component.available)
        let snapshot = try await adapter.reconcile()
        XCTAssertTrue(snapshot.quotas.isEmpty)
    }

    func testQuotaFailureDoesNotDisconnectClaudeSessions() async throws {
        let collector = StubQuotaCollector(result: .failure(.authenticationRequired))
        let adapter = ClaudeAdapter(
            accountID: "personal",
            quotaCollector: collector,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        try await adapter.ingest(sessionStartEnvelope())

        try await adapter.refreshQuota()

        let snapshot = try await adapter.reconcile()
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.sessions.first?.status, .idle)
        let codexbar = await adapter.componentStatus(named: "codexbar")
        let component = try XCTUnwrap(codexbar)
        XCTAssertFalse(component.available)
        XCTAssertEqual(component.component, "codexbar")
    }

    func testLastKnownWindowsSurviveALaterFailureSoStalenessCanShow() async throws {
        let window = try QuotaWindow(
            provider: .claude,
            accountID: "user@example.com",
            windowID: "session",
            usedPercent: 10,
            windowDuration: 18_000,
            resetsAt: Date(timeIntervalSince1970: 20_000),
            fetchedAt: Date(timeIntervalSince1970: 1_000),
            source: "codexbar"
        )
        let collector = StubQuotaCollector(result: .success(.init(
            executablePath: "/usr/local/bin/codexbar",
            windows: [window],
            isPartial: false
        )))
        let adapter = ClaudeAdapter(
            accountID: "personal",
            quotaCollector: collector,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        try await adapter.refreshQuota()

        await collector.setResult(.failure(.timeout))
        try await adapter.refreshQuota()

        // The window is retained with its original timestamp so the desktop can
        // show it as stale rather than silently dropping the last known usage.
        let snapshot = try await adapter.reconcile()
        XCTAssertEqual(snapshot.quotas, [window])
        XCTAssertTrue(window.isStale(now: Date(timeIntervalSince1970: 1_000 + 16 * 60)))
    }

    func testQuotaSetupActionsAreDistinctFromHookActions() async throws {
        let collector = StubQuotaCollector(result: .failure(.sourceUnavailable))
        let adapter = ClaudeAdapter(
            accountID: "personal",
            quotaCollector: collector,
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        let components = try await adapter.configure(.refreshQuota)

        XCTAssertEqual(components.map(\.component), ["codexbar"])
        let attempts = await collector.attempts()
        XCTAssertEqual(attempts, 1)
    }

    private func sessionStartEnvelope() throws -> ProviderHookEnvelope {
        try ProviderHookEnvelope(
            provider: .claude,
            rawJSON: Data("""
            {"hook_event_name":"SessionStart","session_id":"abc123",
            "transcript_path":"/tmp/abc123.jsonl","cwd":"/tmp/repo"}
            """.utf8),
            sourcePID: 42,
            ancestors: [],
            observedAt: Date(timeIntervalSince1970: 1_000)
        )
    }
}

private actor StubQuotaCollector: ClaudeQuotaCollecting {
    private var result: Result<ClaudeQuotaSnapshot, ClaudeQuotaError>
    private var attemptCount = 0

    init(result: Result<ClaudeQuotaSnapshot, ClaudeQuotaError>) {
        self.result = result
    }

    func setResult(_ value: Result<ClaudeQuotaSnapshot, ClaudeQuotaError>) {
        result = value
    }

    func attempts() -> Int { attemptCount }

    func collect() async throws -> ClaudeQuotaSnapshot {
        attemptCount += 1
        return try result.get()
    }
}
