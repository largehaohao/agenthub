import Foundation
import XCTest
import AgentHubQuota
@testable import AgentHubApp

/// Naming, ordering, rounding, and the stale/ended rules for the usage panel.
final class QuotaPresentationTests: XCTestCase {
    func testClaudeQuotaPresentationUsesWindowAndPlanLabels() throws {
        let now = Date(timeIntervalSince1970: 20_000)
        let window = try QuotaWindow(
            provider: .claude,
            accountID: "user@example.com",
            windowID: "weekly",
            label: "Weekly",
            plan: "Pro",
            usedPercent: 40,
            windowDuration: 604_800,
            resetsAt: Date(timeIntervalSince1970: 600_000),
            fetchedAt: Date(timeIntervalSince1970: 1_000),
            source: "claude-statusline"
        )

        let item = QuotaPresentation(window: window, now: now)

        // Provider-specific wording ("Weekly") is replaced by the duration so
        // the same window reads identically across providers.
        XCTAssertEqual(item.title, "7d")
        XCTAssertEqual(item.accountPlan, "user@example.com · Pro")
        XCTAssertTrue(item.isStale)
    }

    func testClaudeSessionWindowIsNamedByDuration() throws {
        let now = Date(timeIntervalSince1970: 1_100)
        let window = try QuotaWindow(
            provider: .claude,
            accountID: "user@example.com",
            windowID: "five_hour",
            label: "Session",
            plan: "Pro",
            usedPercent: 55,
            windowDuration: 18_000,
            resetsAt: Date(timeIntervalSince1970: 600_000),
            fetchedAt: Date(timeIntervalSince1970: 1_000),
            source: "claude-statusline"
        )

        XCTAssertEqual(QuotaPresentation(window: window, now: now).title, "5h")
    }

    /// A window whose reset time has passed is showing a number from a window
    /// that no longer exists, so it must not read as a current figure.
    func testElapsedWindowIsMarkedExpired() throws {
        let now = Date(timeIntervalSince1970: 20_000)
        let window = try QuotaWindow(
            provider: .claude,
            accountID: "a",
            windowID: "five_hour",
            label: "Session",
            usedPercent: 55,
            windowDuration: 18_000,
            resetsAt: Date(timeIntervalSince1970: 10_000),
            fetchedAt: Date(timeIntervalSince1970: 19_900),
            source: "claude-statusline"
        )

        let item = QuotaPresentation(window: window, now: now)

        XCTAssertTrue(item.hasElapsed)
        XCTAssertFalse(item.informsRecommendations)
    }

    func testCurrentWindowIsNotMarkedExpired() throws {
        let now = Date(timeIntervalSince1970: 20_000)
        let window = try QuotaWindow(
            provider: .claude,
            accountID: "a",
            windowID: "five_hour",
            usedPercent: 55,
            windowDuration: 18_000,
            resetsAt: Date(timeIntervalSince1970: 30_000),
            fetchedAt: Date(timeIntervalSince1970: 19_900),
            source: "claude-statusline"
        )

        let item = QuotaPresentation(window: window, now: now)

        XCTAssertFalse(item.hasElapsed)
        XCTAssertTrue(item.informsRecommendations)
    }

    /// Cursor reports Auto / API / Total over the same billing cycle, so the
    /// duration alone would render three identical "31d" titles. The provider's
    /// own label disambiguates them.
    func testWindowsSharingADurationKeepTheirProviderLabel() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let resets = Date(timeIntervalSince1970: 2_700_000)
        func window(_ id: String, _ label: String, _ pct: Double) throws -> QuotaWindow {
            try QuotaWindow(
                provider: .cursor, accountID: "a", windowID: id, label: label, plan: "pro",
                usedPercent: pct, windowDuration: 31 * 24 * 3_600,
                resetsAt: resets, fetchedAt: now, source: "cursor-dashboard"
            )
        }
        let windows = [
            try window("auto", "Auto", 0),
            try window("api", "API", 39.353),
            try window("total", "Total", 34.22),
        ]

        let rows = QuotaProviderRow.rows(from: windows, now: now)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].windows.map(\.title), ["31d · API", "31d · Auto", "31d · Total"])
    }

    /// Windows arrive from a dictionary, so the incoming order is arbitrary.
    /// Any permutation must render in the same order or the strip reshuffles
    /// on every refresh.
    func testSameDurationWindowsOrderIndependentlyOfInputOrder() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let resets = Date(timeIntervalSince1970: 2_700_000)
        func window(_ id: String, _ label: String) throws -> QuotaWindow {
            try QuotaWindow(
                provider: .cursor, accountID: "a", windowID: id, label: label,
                usedPercent: 10, windowDuration: 31 * 24 * 3_600,
                resetsAt: resets, fetchedAt: now, source: "cursor-dashboard"
            )
        }
        let api = try window("api", "API")
        let auto = try window("auto", "Auto")
        let total = try window("total", "Total")
        let expected = ["31d · API", "31d · Auto", "31d · Total"]

        for permutation in [[api, auto, total], [total, api, auto], [auto, total, api]] {
            XCTAssertEqual(
                QuotaProviderRow.rows(from: permutation, now: now)[0].windows.map(\.title),
                expected
            )
        }
    }

    /// A provider whose windows all have distinct durations keeps the short
    /// duration-only name.
    func testWindowsWithDistinctDurationsStayDurationOnly() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let five = try QuotaWindow(
            provider: .claude, accountID: "a", windowID: "five_hour", label: "Session",
            usedPercent: 33, windowDuration: 18_000,
            resetsAt: Date(timeIntervalSince1970: 90_000), fetchedAt: now,
            source: "claude-usage-cache"
        )
        let week = try QuotaWindow(
            provider: .claude, accountID: "a", windowID: "seven_day", label: "Weekly",
            usedPercent: 46, windowDuration: 604_800,
            resetsAt: Date(timeIntervalSince1970: 900_000), fetchedAt: now,
            source: "claude-usage-cache"
        )

        let rows = QuotaProviderRow.rows(from: [week, five], now: now)

        XCTAssertEqual(rows[0].windows.map(\.title), ["5h", "7d"])
    }

    /// Percentages are shown as whole numbers; Cursor reports long fractions.
    func testFractionalPercentIsRoundedForDisplay() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let window = try QuotaWindow(
            provider: .cursor, accountID: "a", windowID: "api", label: "API", plan: "pro",
            usedPercent: 39.35333333333333, windowDuration: 31 * 24 * 3_600,
            resetsAt: Date(timeIntervalSince1970: 2_700_000), fetchedAt: now,
            source: "cursor-dashboard"
        )

        XCTAssertEqual(QuotaPresentation(window: window, now: now).displayPercent, "39%")
    }

    func testQuotaRowsGroupByProviderAndSortShortestWindowFirst() throws {
        let now = Date(timeIntervalSince1970: 1_100)
        let fetched = Date(timeIntervalSince1970: 1_000)
        let claudeWeek = try QuotaWindow(
            provider: .claude, accountID: "a", windowID: "seven_day", label: "Weekly",
            usedPercent: 43, windowDuration: 604_800,
            resetsAt: Date(timeIntervalSince1970: 600_000),
            fetchedAt: fetched, source: "claude-statusline"
        )
        let claudeSession = try QuotaWindow(
            provider: .claude, accountID: "a", windowID: "five_hour", label: "Session",
            usedPercent: 55, windowDuration: 18_000,
            resetsAt: Date(timeIntervalSince1970: 600_000),
            fetchedAt: fetched, source: "claude-statusline"
        )
        let codex = try QuotaWindow(
            provider: .codex, accountID: "b", usedPercent: 98, windowDuration: 604_800,
            resetsAt: Date(timeIntervalSince1970: 600_000),
            fetchedAt: fetched, source: "codex-app-server"
        )

        let rows = QuotaProviderRow.rows(from: [claudeWeek, codex, claudeSession], now: now)

        XCTAssertEqual(rows.map(\.provider), [.claude, .codex])
        XCTAssertEqual(rows[0].windows.map(\.title), ["5h", "7d"])
        XCTAssertEqual(rows[1].windows.map(\.title), ["7d"])
    }

    func testUnlabeledQuotaPresentationFallsBackToDuration() throws {
        let now = Date(timeIntervalSince1970: 1_100)
        let window = try QuotaWindow(
            provider: .codex,
            accountID: "personal",
            usedPercent: 10,
            windowDuration: 18_000,
            resetsAt: Date(timeIntervalSince1970: 600_000),
            fetchedAt: Date(timeIntervalSince1970: 1_000),
            source: "codex-app-server"
        )

        let item = QuotaPresentation(window: window, now: now)

        XCTAssertEqual(item.title, "5h")
        XCTAssertEqual(item.accountPlan, "personal")
        XCTAssertFalse(item.isStale)
    }
}
