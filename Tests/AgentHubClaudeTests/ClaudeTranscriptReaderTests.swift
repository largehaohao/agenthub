import Foundation
import XCTest
import AgentHubCore
@testable import AgentHubClaude

final class ClaudeTranscriptReaderTests: XCTestCase {
    private var root: URL!
    private var reader: ClaudeTranscriptReader!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agenthub-transcripts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reader = ClaudeTranscriptReader(claudeRoot: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testReadsNewestTwentyVisibleTurnsAndIgnoresUnknownRecords() throws {
        let transcript = try copyFixture("transcript")

        let turns = try reader.recentTurns(path: transcript.path, limit: 100)

        XCTAssertEqual(turns.count, 20)
        XCTAssertTrue(turns.allSatisfy { $0.role == "user" || $0.role == "assistant" })
        // The fixture holds 25 turns; the newest 20 are retained in
        // chronological order, so turns 1-5 are dropped.
        XCTAssertEqual(turns.last?.text, "user turn 25")
        XCTAssertEqual(turns.first?.text, "assistant turn 6")
    }

    func testRequestedLimitIsHonouredBelowTheCap() throws {
        let transcript = try copyFixture("transcript")

        let turns = try reader.recentTurns(path: transcript.path, limit: 3)

        XCTAssertEqual(turns.count, 3)
        XCTAssertEqual(turns.last?.text, "user turn 25")
    }

    func testThinkingAndToolInputNeverAppearInVisibleTurns() throws {
        let transcript = try copyFixture("transcript")

        let turns = try reader.recentTurns(path: transcript.path, limit: 20)

        let combined = turns.map(\.text).joined(separator: "\n")
        XCTAssertFalse(combined.contains("hidden reasoning"))
        XCTAssertFalse(combined.contains("rm -rf"))
    }

    func testUnknownAndMalformedRecordsAreSkippedWithoutFailing() throws {
        let transcript = try copyFixture("transcript-unknown")

        let turns = try reader.recentTurns(path: transcript.path, limit: 20)

        XCTAssertEqual(turns.map(\.text), ["keep me", "also keep me"])
    }

    func testRejectsEscapeAndSymlinkOutsideClaudeRoot() throws {
        let outside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agenthub-outside-\(UUID().uuidString).jsonl")
        try Data("{}\n".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let escapingSymlink = root.appendingPathComponent("escape.jsonl")
        try FileManager.default.createSymbolicLink(at: escapingSymlink, withDestinationURL: outside)

        XCTAssertThrowsError(try reader.recentTurns(path: outside.path, limit: 3)) { error in
            XCTAssertEqual(error as? ClaudeTranscriptError, .outsideClaudeRoot)
        }
        XCTAssertThrowsError(try reader.recentTurns(path: escapingSymlink.path, limit: 3)) { error in
            XCTAssertEqual(error as? ClaudeTranscriptError, .outsideClaudeRoot)
        }
    }

    func testRejectsTraversalPathThatResolvesOutsideRoot() throws {
        let traversal = root.path + "/../../etc/passwd"

        XCTAssertThrowsError(try reader.recentTurns(path: traversal, limit: 3)) { error in
            XCTAssertEqual(error as? ClaudeTranscriptError, .outsideClaudeRoot)
        }
    }

    func testMissingTranscriptReportsACoarseError() throws {
        let missing = root.appendingPathComponent("absent.jsonl")

        XCTAssertThrowsError(try reader.recentTurns(path: missing.path, limit: 3)) { error in
            XCTAssertEqual(error as? ClaudeTranscriptError, .unreadableTranscript)
        }
    }

    func testOversizedRecordIsSkippedWithoutExposingItsBody() throws {
        let transcript = root.appendingPathComponent("oversized.jsonl")
        let huge = String(repeating: "A", count: 256 * 1_024 + 10)
        let contents = """
        {"type":"user","uuid":"big","timestamp":"2026-08-12T10:00:00.000Z",\
        "message":{"role":"user","content":[{"type":"text","text":"\(huge)"}]}}
        {"type":"user","uuid":"small","timestamp":"2026-08-12T10:01:00.000Z",\
        "message":{"role":"user","content":[{"type":"text","text":"small"}]}}
        """
        try Data(contents.utf8).write(to: transcript)

        let turns = try reader.recentTurns(path: transcript.path, limit: 20)

        XCTAssertEqual(turns.map(\.text), ["small"])
    }

    func testNonPositiveLimitReturnsNoTurns() throws {
        let transcript = try copyFixture("transcript")

        XCTAssertTrue(try reader.recentTurns(path: transcript.path, limit: 0).isEmpty)
    }

    private func copyFixture(_ name: String) throws -> URL {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Claude/\(name).jsonl")
        let destination = root.appendingPathComponent("\(name).jsonl")
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
}
