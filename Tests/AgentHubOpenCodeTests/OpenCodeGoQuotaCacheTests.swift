import Foundation
import XCTest
import AgentHubCore
@testable import AgentHubOpenCode

/// `reconcile()` runs far more often than quota changes, so the external usage
/// API must not be called every time.
final class OpenCodeGoQuotaCacheTests: XCTestCase {
    func testSecondFetchWithinIntervalReusesCachedWindows() async throws {
        let counter = CallCounter()
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000))
        let cache = OpenCodeGoQuotaCache(
            minimumInterval: 900,
            now: { clock.value },
            fetch: {
                await counter.increment()
                return [try! Self.window(percent: 19, at: clock.value)]
            }
        )

        _ = await cache.windows()
        clock.value = Date(timeIntervalSince1970: 1_100)  // +100s, inside interval
        let second = await cache.windows()

        let calls = await counter.count
        XCTAssertEqual(calls, 1, "must not re-hit the API inside the interval")
        XCTAssertEqual(second.first?.usedPercent, 19, "cached value is still served")
    }

    func testFetchAfterIntervalRefreshes() async throws {
        let counter = CallCounter()
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000))
        let cache = OpenCodeGoQuotaCache(
            minimumInterval: 900,
            now: { clock.value },
            fetch: {
                await counter.increment()
                return [try! Self.window(percent: 19, at: clock.value)]
            }
        )

        _ = await cache.windows()
        clock.value = Date(timeIntervalSince1970: 2_000)  // +1000s, past interval
        _ = await cache.windows()

        let calls = await counter.count
        XCTAssertEqual(calls, 2)
    }

    /// A failed refresh must keep the last good reading rather than blanking the
    /// strip, matching §11 of the design.
    func testFailedRefreshKeepsPreviousWindows() async throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000))
        let shouldFail = Flag()
        let cache = OpenCodeGoQuotaCache(
            minimumInterval: 900,
            now: { clock.value },
            fetch: {
                if await shouldFail.value { return [] }
                return [try! Self.window(percent: 19, at: clock.value)]
            }
        )

        _ = await cache.windows()
        await shouldFail.set(true)
        clock.value = Date(timeIntervalSince1970: 2_000)
        let afterFailure = await cache.windows()

        XCTAssertEqual(afterFailure.first?.usedPercent, 19)
    }

    /// An explicit user refresh bypasses the interval.
    func testForcedRefreshIgnoresInterval() async throws {
        let counter = CallCounter()
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000))
        let cache = OpenCodeGoQuotaCache(
            minimumInterval: 900,
            now: { clock.value },
            fetch: {
                await counter.increment()
                return [try! Self.window(percent: 19, at: clock.value)]
            }
        )

        _ = await cache.windows()
        _ = await cache.windows(force: true)

        let calls = await counter.count
        XCTAssertEqual(calls, 2)
    }

    private static func window(percent: Double, at date: Date) throws -> QuotaWindow {
        try QuotaWindow(
            provider: .openCode,
            accountID: "go",
            windowID: "weekly",
            usedPercent: percent,
            windowDuration: 7 * 24 * 3_600,
            resetsAt: date.addingTimeInterval(86_400),
            fetchedAt: date,
            source: "opencode-go"
        )
    }
}

private final class MutableClock: @unchecked Sendable {
    var value: Date
    init(_ value: Date) { self.value = value }
}

private actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private actor Flag {
    private(set) var value = false
    func set(_ newValue: Bool) { value = newValue }
}
