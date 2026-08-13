import Foundation
import XCTest
import AgentHubCore
@testable import AgentHubClaude

/// Shape captured from the live `GET https://api.anthropic.com/api/oauth/usage`
/// response, which is the same payload Claude Code caches locally.
final class ClaudeUsageAPITests: XCTestCase {
    private let liveShape = """
    {"five_hour":{"utilization":96.0,"resets_at":"2026-08-13T09:50:00.305145+00:00",
      "limit_dollars":null,"used_dollars":null,"remaining_dollars":null},
     "seven_day":{"utilization":58.0,"resets_at":"2026-08-17T01:00:00.305173+00:00",
      "limit_dollars":null,"used_dollars":null,"remaining_dollars":null},
     "seven_day_opus":null,"seven_day_sonnet":null,
     "nimbus_quill":{"utilization":0.0,"resets_at":null},
     "extra_usage":{"is_enabled":true,"used_credits":4259.0,"utilization":null}}
    """

    func testDecodesFiveHourAndSevenDayWindows() throws {
        let fetched = Date(timeIntervalSince1970: 1_786_600_000)

        let windows = try ClaudeUsageWindows.decode(
            Data(liveShape.utf8),
            accountID: "default",
            fetchedAt: fetched,
            source: ClaudeUsageAPIClient.source
        )

        XCTAssertEqual(windows.count, 2)
        let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
        XCTAssertEqual(byID["five_hour"]?.usedPercent, 96)
        XCTAssertEqual(byID["five_hour"]?.windowDuration, 5 * 3_600)
        XCTAssertEqual(byID["seven_day"]?.usedPercent, 58)
        XCTAssertEqual(byID["seven_day"]?.windowDuration, 7 * 24 * 3_600)
        XCTAssertTrue(windows.allSatisfy { $0.source == "claude-usage-api" })
        XCTAssertTrue(windows.allSatisfy { $0.fetchedAt == fetched })
    }

    /// Windows the account does not have report null; emitting 0% would read as
    /// "plenty left" rather than "unknown".
    func testSkipsNullAndUnknownWindows() throws {
        let windows = try ClaudeUsageWindows.decode(
            Data(liveShape.utf8),
            accountID: "default",
            fetchedAt: Date(),
            source: ClaudeUsageAPIClient.source
        )

        XCTAssertFalse(windows.contains { $0.windowID == "seven_day_opus" })
        XCTAssertFalse(windows.contains { $0.windowID == "nimbus_quill" })
    }

    func testMalformedPayloadYieldsNoWindows() throws {
        let windows = try ClaudeUsageWindows.decode(
            Data("{ not json".utf8),
            accountID: "default",
            fetchedAt: Date(),
            source: ClaudeUsageAPIClient.source
        )

        XCTAssertTrue(windows.isEmpty)
    }

    /// The reset times carry fractional seconds, which a plain ISO8601 parser
    /// rejects -- the defect that previously froze Claude usage.
    func testFractionalSecondResetTimesParse() throws {
        let windows = try ClaudeUsageWindows.decode(
            Data(liveShape.utf8),
            accountID: "default",
            fetchedAt: Date(),
            source: ClaudeUsageAPIClient.source
        )

        XCTAssertEqual(windows.count, 2)
        XCTAssertTrue(windows.allSatisfy { $0.resetsAt > Date(timeIntervalSince1970: 1_786_000_000) })
    }

    // MARK: - Credential handling

    func testCredentialParsesTokenAndExpiry() throws {
        let payload = """
        {"claudeAiOauth":{"accessToken":"tok-123","refreshToken":"r",
        "expiresAt":1786631766712,"subscriptionType":"pro"}}
        """

        let credential = try XCTUnwrap(
            ClaudeOAuthCredential(json: Data(payload.utf8))
        )

        XCTAssertEqual(credential.token, "tok-123")
        XCTAssertEqual(
            try XCTUnwrap(credential.expiresAt).timeIntervalSince1970,
            1_786_631_766.712,
            accuracy: 0.01
        )
        XCTAssertFalse(credential.isExpired(now: Date(timeIntervalSince1970: 1_786_000_000)))
        XCTAssertTrue(credential.isExpired(now: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    func testMalformedCredentialIsRejected() throws {
        XCTAssertNil(ClaudeOAuthCredential(json: Data("{}".utf8)))
        XCTAssertNil(ClaudeOAuthCredential(json: Data("not json".utf8)))
    }

    /// The token is held only to build one request header; it must never reach
    /// a quota window that gets persisted.
    func testDecodedWindowsCarryNoCredential() throws {
        let windows = try ClaudeUsageWindows.decode(
            Data(liveShape.utf8),
            accountID: "default",
            fetchedAt: Date(),
            source: ClaudeUsageAPIClient.source
        )

        for window in windows {
            let encoded = String(data: try JSONEncoder().encode(window), encoding: .utf8) ?? ""
            XCTAssertFalse(encoded.lowercased().contains("bearer"))
            XCTAssertFalse(encoded.lowercased().contains("token"))
        }
    }
}
