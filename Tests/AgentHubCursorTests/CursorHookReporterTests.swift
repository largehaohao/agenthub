import Foundation
import XCTest
import AgentHubCore
@testable import AgentHubCursor

final class CursorHookReporterTests: XCTestCase {
    func testDecisionPathReturnsAskWhenSendFails() async throws {
        let reporter = CursorHookReporter(
            send: { _ in throw URLError(.cannotConnectToHost) },
            awaitPermission: { _, _ in .ask }
        )
        let out = await reporter.handle(
            stdin: try fixtureData("before-shell-execution"),
            sourcePID: 1
        )
        let obj = try JSONSerialization.jsonObject(with: out.stdout) as! [String: Any]
        XCTAssertEqual(obj["permission"] as? String, "ask")
    }

    func testObservationPathReturnsEmptyObject() async throws {
        let reporter = CursorHookReporter(
            send: { _ in .init(requestID: nil) },
            awaitPermission: { _, _ in .allow }
        )
        let out = await reporter.handle(
            stdin: try fixtureData("session-start"),
            sourcePID: 1
        )
        XCTAssertEqual(String(decoding: out.stdout, as: UTF8.self), "{}")
    }

    func testDecisionPathAwaitsAllow() async throws {
        let id = UUID()
        let reporter = CursorHookReporter(
            send: { _ in .init(requestID: id) },
            awaitPermission: { requestID, _ in
                XCTAssertEqual(requestID, id)
                return .allow
            }
        )
        let out = await reporter.handle(
            stdin: try fixtureData("before-shell-execution"),
            sourcePID: 1
        )
        let obj = try JSONSerialization.jsonObject(with: out.stdout) as! [String: Any]
        XCTAssertEqual(obj["permission"] as? String, "allow")
    }

    private func fixtureData(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Cursor/\(name).json")
        return try Data(contentsOf: url)
    }
}
