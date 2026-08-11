import Foundation
import XCTest
@testable import AgentHubOpenCode

final class ServerSentEventsTests: XCTestCase {
    func testParserHandlesFragmentedFramesAndUnknownEvent() throws {
        var parser = ServerSentEventParser()

        let first = try parser.append(Data(
            "event: message.part.updated\ndata: {\"type\":\"message.part.updated\"".utf8
        ))
        XCTAssertTrue(first.isEmpty)

        let frames = try parser.append(Data(
            ",\"properties\":{}}\n\nevent: future.event\ndata: {\"type\":\"future.event\",\"properties\":{}}\n\n".utf8
        ))

        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].event, "message.part.updated")
        XCTAssertEqual(
            try OpenCodeEvent(data: frames[1].data),
            OpenCodeEvent(type: "future.event", propertiesJSON: Data("{}".utf8))
        )
    }

    func testParserJoinsDataLinesAndIgnoresHeartbeatComments() throws {
        var parser = ServerSentEventParser()

        let frames = try parser.append(Data(
            ": heartbeat\ndata: first\ndata: second\r\n\r\n".utf8
        ))

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(String(decoding: frames[0].data, as: UTF8.self), "first\nsecond")
    }
}
