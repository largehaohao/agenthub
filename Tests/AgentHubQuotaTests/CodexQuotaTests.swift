import XCTest
@testable import AgentHubQuota

/// Shape captured from a live `codex app-server` `account/rateLimits/read`.
final class CodexQuotaTests: XCTestCase {
    private let live = """
    {"rateLimits":{"limit_id":"codex","plan_type":"plus",
      "primary":{"used_percent":98.0,"window_minutes":10080,"resets_at":1787012257},
      "secondary":{"used_percent":12.5,"window_minutes":300,"resets_at":1787000000}}}
    """

    func testDecodesSnakeCaseWindows() throws {
        let windows = try CodexQuotaDecoder(accountID: "default")
            .decode(Data(live.utf8), now: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows.map(\.usedPercent).sorted(), [12.5, 98])
        XCTAssertEqual(Set(windows.map(\.windowDuration)), [300 * 60, 10_080 * 60])
        XCTAssertEqual(Set(windows.map(\.id)).count, 2)
        XCTAssertTrue(windows.allSatisfy { $0.plan == "plus" })
        XCTAssertTrue(windows.allSatisfy { $0.source == "codex-app-server" })
    }

    /// An older or newer server spelling camelCase must still parse rather than
    /// silently yielding no windows.
    func testAcceptsCamelCaseSpelling() throws {
        let camel = """
        {"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1700018000}}}
        """

        let windows = try CodexQuotaDecoder(accountID: "default")
            .decode(Data(camel.utf8), now: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertEqual(windows.map(\.usedPercent), [25])
    }

    func testMalformedPayloadYieldsNoWindows() throws {
        let windows = try CodexQuotaDecoder(accountID: "default")
            .decode(Data("{ not json".utf8), now: Date())
        XCTAssertTrue(windows.isEmpty)
    }

    /// A window missing its percentage carries no usable number; emitting 0%
    /// would read as "plenty left".
    func testSkipsIncompleteWindows() throws {
        let partial = """
        {"rateLimits":{"primary":{"window_minutes":300,"resets_at":1787000000},
          "secondary":{"used_percent":40,"window_minutes":10080,"resets_at":1787012257}}}
        """

        let windows = try CodexQuotaDecoder(accountID: "default")
            .decode(Data(partial.utf8), now: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertEqual(windows.map(\.windowID), ["secondary"])
    }
}
