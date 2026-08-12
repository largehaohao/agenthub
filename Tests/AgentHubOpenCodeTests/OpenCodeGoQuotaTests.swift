import Foundation
import XCTest
import AgentHubCore
@testable import AgentHubOpenCode

/// Shape captured from the live `https://opencode.ai/zen/go/v1/usage` response.
final class OpenCodeGoQuotaTests: XCTestCase {
    private let liveShape = """
    {"usage":{
      "rolling":{"status":"ok","percent":0,"resetsAt":"2026-08-12T15:30:21.723Z"},
      "weekly":{"status":"ok","percent":19,"resetsAt":"2026-08-17T00:00:00.723Z"},
      "monthly":{"status":"ok","percent":23,"resetsAt":"2026-09-03T10:30:24.723Z"}}}
    """

    func testDecodesAllThreeWindows() throws {
        let now = Date(timeIntervalSince1970: 1_786_533_000)

        let windows = try OpenCodeGoQuotaDecoder(accountID: "go")
            .decode(Data(liveShape.utf8), now: now)

        XCTAssertEqual(windows.count, 3)
        let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
        XCTAssertEqual(byID["rolling"]?.usedPercent, 0)
        XCTAssertEqual(byID["weekly"]?.usedPercent, 19)
        XCTAssertEqual(byID["monthly"]?.usedPercent, 23)
        XCTAssertTrue(windows.allSatisfy { $0.provider == .openCode })
        XCTAssertTrue(windows.allSatisfy { $0.source == "opencode-go" })
    }

    /// Durations drive the canonical 5h / 7d / 30d labels in the strip.
    func testWindowDurationsMatchTheirNames() throws {
        let windows = try OpenCodeGoQuotaDecoder(accountID: "go")
            .decode(Data(liveShape.utf8), now: Date(timeIntervalSince1970: 1_786_533_000))

        let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
        XCTAssertEqual(byID["rolling"]?.windowDuration, 5 * 3_600)
        XCTAssertEqual(byID["weekly"]?.windowDuration, 7 * 24 * 3_600)
        XCTAssertEqual(byID["monthly"]?.windowDuration, 30 * 24 * 3_600)
        XCTAssertEqual(QuotaWindow.durationLabel(5 * 3_600), "5h")
        XCTAssertEqual(QuotaWindow.durationLabel(7 * 24 * 3_600), "7d")
        XCTAssertEqual(QuotaWindow.durationLabel(30 * 24 * 3_600), "30d")
    }

    /// A window reporting a non-ok status carries no usable number; emitting 0%
    /// would read as "plenty left".
    func testSkipsWindowsWithoutOkStatus() throws {
        let payload = """
        {"usage":{
          "rolling":{"status":"unavailable","percent":null,"resetsAt":null},
          "weekly":{"status":"ok","percent":19,"resetsAt":"2026-08-17T00:00:00.723Z"}}}
        """

        let windows = try OpenCodeGoQuotaDecoder(accountID: "go")
            .decode(Data(payload.utf8), now: Date(timeIntervalSince1970: 1_786_533_000))

        XCTAssertEqual(windows.map(\.windowID), ["weekly"])
    }

    func testMalformedPayloadYieldsNoWindows() throws {
        let windows = try OpenCodeGoQuotaDecoder(accountID: "go")
            .decode(Data("{ not json".utf8), now: Date())

        XCTAssertTrue(windows.isEmpty)
    }

    /// The key is read into memory for the request only; it must never reach a
    /// persisted window.
    func testDecodedWindowsCarryNoCredential() throws {
        let windows = try OpenCodeGoQuotaDecoder(accountID: "go")
            .decode(Data(liveShape.utf8), now: Date())

        for window in windows {
            let encoded = String(data: try JSONEncoder().encode(window), encoding: .utf8) ?? ""
            XCTAssertFalse(encoded.lowercased().contains("bearer"))
            XCTAssertFalse(encoded.lowercased().contains("key"))
        }
    }
}
