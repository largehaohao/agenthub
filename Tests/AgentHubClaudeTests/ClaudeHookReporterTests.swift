import Foundation
import XCTest
import AgentHubCore
@testable import AgentHubClaude

final class ClaudeHookReporterTests: XCTestCase {
    func testReporterSendsBoundedEnvelopeWithoutEnvironment() async throws {
        let sink = RecordingHookSink()
        let reporter = makeReporter(sink: sink)

        try await reporter.report(stdin: validPayload, sourcePID: 41)

        let recorded = await sink.values()
        XCTAssertEqual(recorded.count, 1)
        let envelope = try XCTUnwrap(recorded.first)
        XCTAssertEqual(envelope.provider, .claude)
        XCTAssertEqual(envelope.sourcePID, 41)
        XCTAssertEqual(envelope.observedAt, Date(timeIntervalSince1970: 1))

        let payload = try XCTUnwrap(String(data: envelope.rawJSON, encoding: .utf8))
        XCTAssertFalse(payload.contains("PATH"))
        XCTAssertFalse(payload.contains("ANTHROPIC_API_KEY"))
    }

    func testReporterAttachesBoundedCurrentUserAncestry() async throws {
        let sink = RecordingHookSink()
        let reporter = makeReporter(sink: sink)

        try await reporter.report(stdin: validPayload, sourcePID: 41)

        let recorded = await sink.values()
        let envelope = try XCTUnwrap(recorded.first)
        XCTAssertEqual(envelope.ancestors.map(\.pid), [40])
        XCTAssertEqual(envelope.ancestors.first?.command, "claude")
    }

    func testOversizedStdinIsRejectedBeforeSending() async throws {
        let sink = RecordingHookSink()
        let reporter = makeReporter(sink: sink)
        let oversized = Data(repeating: 0x41, count: ProviderHookEnvelope.maximumPayloadBytes + 1)

        do {
            try await reporter.report(stdin: oversized, sourcePID: 41)
            XCTFail("expected an oversized payload to be rejected")
        } catch {
            XCTAssertEqual(error as? ProviderHookEnvelopeError, .oversizedPayload)
        }
        let recorded = await sink.values()
        XCTAssertTrue(recorded.isEmpty)
    }

    func testUnparsablePayloadIsNotForwarded() async throws {
        let sink = RecordingHookSink()
        let reporter = makeReporter(sink: sink)

        do {
            try await reporter.report(stdin: Data("not json".utf8), sourcePID: 41)
            XCTFail("expected a malformed payload to be rejected")
        } catch {
            XCTAssertEqual(error as? ClaudeHookDecodingError, .malformedPayload)
        }
        let recorded = await sink.values()
        XCTAssertTrue(recorded.isEmpty)
    }

    func testUnknownEventStillReachesTheDaemon() async throws {
        let sink = RecordingHookSink()
        let reporter = makeReporter(sink: sink)
        let payload = Data("""
        {
          "hook_event_name": "FutureEvent",
          "session_id": "abc123",
          "transcript_path": "/tmp/abc123.jsonl",
          "cwd": "/tmp"
        }
        """.utf8)

        try await reporter.report(stdin: payload, sourcePID: 41)

        let recorded = await sink.values()
        XCTAssertEqual(recorded.count, 1)
    }

    private var validPayload: Data {
        Data("""
        {
          "hook_event_name": "SessionStart",
          "session_id": "abc123",
          "transcript_path": "/tmp/abc123.jsonl",
          "cwd": "/tmp"
        }
        """.utf8)
    }

    private func makeReporter(sink: RecordingHookSink) -> ClaudeHookReporter {
        ClaudeHookReporter(
            ancestry: { _ in
                [
                    ProcessObservation(
                        pid: 40,
                        parentPID: 1,
                        uid: 501,
                        tty: "ttys001",
                        command: "claude"
                    ),
                ]
            },
            send: { await sink.record($0) },
            now: { Date(timeIntervalSince1970: 1) }
        )
    }
}

actor RecordingHookSink {
    private var recorded: [ProviderHookEnvelope] = []

    func record(_ envelope: ProviderHookEnvelope) {
        recorded.append(envelope)
    }

    func values() -> [ProviderHookEnvelope] { recorded }
}
