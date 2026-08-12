import Foundation
import XCTest
import AgentHubCore
@testable import AgentHubClaude

/// `~/.claude.json` carries Claude Code's own `cachedUsageUtilization`, which is
/// refreshed independently of whether a status line ever renders. Shape captured
/// from the real file.
final class ClaudeUsageCacheReaderTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agenthub-usage-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent(".claude.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testReadsFiveHourAndSevenDayWindows() throws {
        try write("""
        {"cachedUsageUtilization":{"fetchedAtMs":1786532498571,
        "utilization":{
          "five_hour":{"utilization":33,"resets_at":"2026-08-12T14:50:00.458358+00:00"},
          "seven_day":{"utilization":46,"resets_at":"2026-08-17T01:00:00.458381+00:00"}}}}
        """)

        let windows = try ClaudeUsageCacheReader(fileURL: fileURL).read()

        XCTAssertEqual(windows.count, 2)
        let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
        XCTAssertEqual(byID["five_hour"]?.usedPercent, 33)
        XCTAssertEqual(byID["five_hour"]?.windowDuration, 5 * 3_600)
        XCTAssertEqual(byID["seven_day"]?.usedPercent, 46)
        XCTAssertEqual(byID["seven_day"]?.windowDuration, 7 * 24 * 3_600)
        XCTAssertTrue(windows.allSatisfy { $0.source == "claude-usage-cache" })
    }

    /// `fetchedAtMs` is the real observation time, so staleness is reported
    /// honestly instead of being reset by the moment AgentHub happened to read.
    func testUsesCacheTimestampAsFetchedAt() throws {
        try write("""
        {"cachedUsageUtilization":{"fetchedAtMs":1786532498571,
        "utilization":{"five_hour":{"utilization":33,
        "resets_at":"2026-08-12T14:50:00.458358+00:00"}}}}
        """)

        let window = try XCTUnwrap(ClaudeUsageCacheReader(fileURL: fileURL).read().first)

        XCTAssertEqual(
            window.fetchedAt.timeIntervalSince1970,
            1_786_532_498.571,
            accuracy: 0.01
        )
    }

    /// Windows the account does not have report a null utilization; emitting 0%
    /// would read as "plenty left" rather than "unknown".
    func testSkipsNullUtilizationWindows() throws {
        try write("""
        {"cachedUsageUtilization":{"fetchedAtMs":1786532498571,
        "utilization":{
          "five_hour":{"utilization":33,"resets_at":"2026-08-12T14:50:00.458358+00:00"},
          "seven_day_opus":null,
          "nimbus_quill":{"utilization":0,"resets_at":null}}}}
        """)

        let windows = try ClaudeUsageCacheReader(fileURL: fileURL).read()

        XCTAssertEqual(windows.map(\.windowID), ["five_hour"])
    }

    func testMissingFileYieldsNoWindowsRatherThanThrowing() throws {
        let reader = ClaudeUsageCacheReader(
            fileURL: directory.appendingPathComponent("absent.json")
        )

        XCTAssertEqual(try reader.read().count, 0)
    }

    func testMalformedFileYieldsNoWindows() throws {
        try write("{ not json")

        XCTAssertEqual(try ClaudeUsageCacheReader(fileURL: fileURL).read().count, 0)
    }

    /// The file also holds OAuth account details and project history; nothing
    /// but usage numbers may be lifted out of it.
    func testReadsNoIdentifyingFieldsFromTheFile() throws {
        try write("""
        {"oauthAccount":{"emailAddress":"user@example.com","accountUuid":"secret-uuid"},
        "cachedUsageUtilization":{"fetchedAtMs":1786532498571,"accountUuid":"secret-uuid",
        "utilization":{"five_hour":{"utilization":33,
        "resets_at":"2026-08-12T14:50:00.458358+00:00"}}}}
        """)

        let window = try XCTUnwrap(ClaudeUsageCacheReader(fileURL: fileURL).read().first)

        let encoded = String(data: try JSONEncoder().encode(window), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("secret-uuid"))
        XCTAssertFalse(encoded.contains("user@example.com"))
    }

    private func write(_ json: String) throws {
        try Data(json.utf8).write(to: fileURL)
    }
}
