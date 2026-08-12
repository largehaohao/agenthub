import Foundation
import XCTest
import AgentHubCore
@testable import AgentHubClaude

final class ClaudeStatusLineQuotaTests: XCTestCase {
    private let decoder = ClaudeStatusLineDecoder()

    func testRealPercentagesAndResetsMapToQuotaWindows() throws {
        let report = try decoder.decode(fixture("statusline-payload"))

        XCTAssertEqual(report.sessionID, "abc123")
        XCTAssertEqual(report.windows.map(\.windowID), ["five_hour", "seven_day"])

        let session = try XCTUnwrap(report.windows.first)
        XCTAssertEqual(session.usedPercent, 42.5)
        XCTAssertEqual(session.label, "Session")
        XCTAssertEqual(session.windowDuration, 5 * 3_600)
        XCTAssertEqual(
            session.resetsAt,
            ISO8601DateFormatter().date(from: "2026-08-12T09:00:00Z")
        )
        // The source is Claude Code itself, not a third-party helper.
        XCTAssertEqual(session.source, "claude-statusline")

        let weekly = try XCTUnwrap(report.windows.last)
        XCTAssertEqual(weekly.usedPercent, 12)
        XCTAssertEqual(weekly.label, "Weekly")
        XCTAssertEqual(weekly.windowDuration, 7 * 24 * 3_600)
    }

    func testWindowsForTheSameAccountDoNotCollide() throws {
        let report = try decoder.decode(fixture("statusline-payload"))
        let ids = Set(report.windows.map(\.id))
        XCTAssertEqual(ids.count, report.windows.count)
    }

    func testPayloadWithoutRateLimitsYieldsNoWindowsRatherThanZeroes() throws {
        let report = try decoder.decode(fixture("statusline-no-limits"))

        // Reporting 0% would be a fabricated number; absent data means absent.
        XCTAssertTrue(report.windows.isEmpty)
        XCTAssertEqual(report.sessionID, "abc123")
    }

    func testOnlyOneWindowPresentStillReports() throws {
        let payload = Data("""
        {"session_id":"s","rate_limits":{"five_hour":
        {"used_percentage":10,"resets_at":"2026-08-12T09:00:00Z"}}}
        """.utf8)

        let report = try decoder.decode(payload)
        XCTAssertEqual(report.windows.map(\.windowID), ["five_hour"])
    }

    func testWindowMissingResetTimeIsSkipped() throws {
        let payload = Data("""
        {"session_id":"s","rate_limits":{"five_hour":{"used_percentage":10}}}
        """.utf8)

        XCTAssertTrue(try decoder.decode(payload).windows.isEmpty)
    }

    func testOutOfRangePercentageIsSkippedRatherThanClamped() throws {
        let payload = Data("""
        {"session_id":"s","rate_limits":{"five_hour":
        {"used_percentage":900,"resets_at":"2026-08-12T09:00:00Z"}}}
        """.utf8)

        XCTAssertTrue(try decoder.decode(payload).windows.isEmpty)
    }

    func testMalformedPayloadIsRejectedWithoutLeakingContent() {
        let payload = Data("""
        {"session_id":"s","secret":"raw-secret-token","rate_limits":
        """.utf8)

        XCTAssertThrowsError(try decoder.decode(payload)) { error in
            XCTAssertEqual(error as? ClaudeStatusLineError, .malformedPayload)
            XCTAssertFalse(String(describing: error).contains("raw-secret-token"))
        }
    }

    func testOversizedPayloadIsRejected() {
        let payload = Data(
            repeating: 0x20,
            count: ClaudeStatusLineDecoder.maximumPayloadBytes + 1
        )
        XCTAssertThrowsError(try decoder.decode(payload)) { error in
            XCTAssertEqual(error as? ClaudeStatusLineError, .malformedPayload)
        }
    }

    func testDecodedReportCarriesNoPromptOrTranscriptText() throws {
        let payload = Data("""
        {"session_id":"s","cwd":"/tmp","transcript_path":"/tmp/t.jsonl",
        "last_prompt":"my secret prompt","rate_limits":{"five_hour":
        {"used_percentage":10,"resets_at":"2026-08-12T09:00:00Z"}}}
        """.utf8)

        let report = try decoder.decode(payload)
        XCTAssertFalse(String(describing: report).contains("my secret prompt"))
        XCTAssertFalse(String(describing: report).contains("t.jsonl"))
    }

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Claude/\(name).json")
        return try Data(contentsOf: url)
    }
}
