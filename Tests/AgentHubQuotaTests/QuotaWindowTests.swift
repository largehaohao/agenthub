import XCTest
@testable import AgentHubQuota

final class QuotaWindowTests: XCTestCase {
    func testDurationLabelUsesHoursThenDays() {
        XCTAssertEqual(QuotaWindow.durationLabel(5 * 3_600), "5h")
        XCTAssertEqual(QuotaWindow.durationLabel(7 * 24 * 3_600), "7d")
        XCTAssertEqual(QuotaWindow.durationLabel(30 * 24 * 3_600), "30d")
    }

    func testIdentityIncludesWindowIDSoSiblingsStayDistinct() throws {
        func window(_ id: String) throws -> QuotaWindow {
            try QuotaWindow(
                provider: .cursor, accountID: "a", windowID: id,
                usedPercent: 10, windowDuration: 31 * 24 * 3_600,
                resetsAt: Date(timeIntervalSince1970: 2_000),
                fetchedAt: Date(timeIntervalSince1970: 1_000),
                source: "cursor-dashboard"
            )
        }
        XCTAssertNotEqual(try window("api").id, try window("auto").id)
    }

    func testPercentOutOfRangeIsRejected() {
        XCTAssertThrowsError(
            try QuotaWindow(
                provider: .claude, accountID: "a", usedPercent: 101,
                windowDuration: 3_600, resetsAt: Date(), fetchedAt: Date(),
                source: "t"
            )
        )
    }

    func testStalenessUsesFetchedAt() throws {
        let window = try QuotaWindow(
            provider: .claude, accountID: "a", usedPercent: 10,
            windowDuration: 3_600, resetsAt: Date(timeIntervalSince1970: 10_000),
            fetchedAt: Date(timeIntervalSince1970: 1_000), source: "t"
        )
        XCTAssertFalse(window.isStale(now: Date(timeIntervalSince1970: 1_100)))
        XCTAssertTrue(window.isStale(now: Date(timeIntervalSince1970: 2_000)))
    }

    /// `displayName` moves here from the dashboard, which is being deleted.
    func testProviderDisplayNames() {
        XCTAssertEqual(Provider.codex.displayName, "Codex")
        XCTAssertEqual(Provider.claude.displayName, "Claude")
        XCTAssertEqual(Provider.cursor.displayName, "Cursor")
        XCTAssertEqual(Provider.openCode.displayName, "OpenCode")
    }
}
