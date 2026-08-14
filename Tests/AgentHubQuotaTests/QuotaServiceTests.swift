import XCTest
@testable import AgentHubQuota

final class QuotaServiceTests: XCTestCase {
    private func window(_ provider: Provider, _ pct: Double, at date: Date) throws -> QuotaWindow {
        try QuotaWindow(
            provider: provider, accountID: "a", windowID: "w", usedPercent: pct,
            windowDuration: 3_600, resetsAt: date.addingTimeInterval(3_600),
            fetchedAt: date, source: "test"
        )
    }

    func testMergesEveryProvider() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let claude = try window(.claude, 10, at: now)
        let codex = try window(.codex, 20, at: now)
        let service = QuotaService(
            sources: [
                .init(provider: .claude) { [claude] },
                .init(provider: .codex) { [codex] },
            ],
            now: { now }
        )

        let windows = await service.windows()

        XCTAssertEqual(Set(windows.map(\.provider)), [.claude, .codex])
    }

    /// A signed-out or unreachable provider must not take the others with it.
    func testOneEmptySourceDoesNotBlockOthers() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let codex = try window(.codex, 20, at: now)
        let service = QuotaService(
            sources: [
                .init(provider: .claude) { [] },
                .init(provider: .codex) { [codex] },
            ],
            now: { now }
        )

        let windows = await service.windows()

        XCTAssertEqual(windows.map(\.provider), [.codex])
    }

    func testSecondCallInsideIntervalDoesNotRefetch() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let counter = Counter()
        let claude = try window(.claude, 10, at: now)
        let service = QuotaService(
            sources: [.init(provider: .claude) {
                await counter.increment()
                return [claude]
            }],
            minimumInterval: 900,
            now: { now }
        )

        _ = await service.windows()
        _ = await service.windows()

        let calls = await counter.count
        XCTAssertEqual(calls, 1)
    }

    func testForceBypassesTheInterval() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let counter = Counter()
        let claude = try window(.claude, 10, at: now)
        let service = QuotaService(
            sources: [.init(provider: .claude) {
                await counter.increment()
                return [claude]
            }],
            minimumInterval: 900,
            now: { now }
        )

        _ = await service.windows()
        _ = await service.windows(force: true)

        let calls = await counter.count
        XCTAssertEqual(calls, 2)
    }

    /// A provider that has reported nothing is retried far sooner than one
    /// holding a reading: the long interval protects numbers we already have,
    /// and an empty provider has none.
    func testEmptyProviderIsRetriedSoonerThanAReportingOne() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000))
        let empty = Counter()
        let reporting = Counter()
        let codex = try window(.codex, 20, at: clock.now)
        let service = QuotaService(
            sources: [
                .init(provider: .claude) {
                    await empty.increment()
                    return []
                },
                .init(provider: .codex) {
                    await reporting.increment()
                    return [codex]
                },
            ],
            minimumInterval: 900,
            now: { clock.now }
        )

        _ = await service.windows()
        clock.advance(by: QuotaService.emptyRetryInterval + 1)
        _ = await service.windows()

        let emptyCalls = await empty.count
        let reportingCalls = await reporting.count
        XCTAssertEqual(emptyCalls, 2, "the provider with nothing should be tried again")
        XCTAssertEqual(reportingCalls, 1, "the provider with a reading should wait out the interval")
    }

    /// The short retry is still a limit, not an invitation to poll on every
    /// panel open.
    func testEmptyProviderIsNotRetriedImmediately() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let counter = Counter()
        let service = QuotaService(
            sources: [.init(provider: .claude) {
                await counter.increment()
                return []
            }],
            minimumInterval: 900,
            now: { now }
        )

        _ = await service.windows()
        _ = await service.windows()

        let calls = await counter.count
        XCTAssertEqual(calls, 1)
    }

    /// A transient failure must leave the last real numbers on screen rather
    /// than blanking the panel.
    func testFailedRefreshKeepsPreviousWindows() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let claude = try window(.claude, 10, at: now)
        let failing = Flag()
        let service = QuotaService(
            sources: [.init(provider: .claude) {
                await failing.value ? [] : [claude]
            }],
            minimumInterval: 0,
            now: { now }
        )

        _ = await service.windows()
        await failing.set(true)
        let after = await service.windows()

        XCTAssertEqual(after.map(\.usedPercent), [10])
    }
}

/// A movable clock, so the interval can be crossed without sleeping.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return date
    }
    func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        date.addTimeInterval(interval)
    }
}

private actor Counter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private actor Flag {
    private(set) var value = false
    func set(_ newValue: Bool) { value = newValue }
}
