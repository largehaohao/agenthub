import Foundation
import XCTest
import AgentHubCore
@testable import AgentHubOpenCode

final class OpenCodeHTTPClientTests: XCTestCase {
    func testCreateSessionUsesDirectoryBodyAndBasicAuth() async throws {
        let transport = RecordingOpenCodeHTTPTransport()
        await transport.enqueue(status: 200, body: try fixture(named: "health-session"))
        let client = OpenCodeHTTPClient(
            baseURL: URL(string: "http://127.0.0.1:41789")!,
            authorization: .basic(username: "opencode", password: "secret"),
            transport: transport
        )

        let session = try await client.createSession(
            directory: "/tmp/repository",
            title: "AgentHub task",
            agent: "build",
            model: LaunchModelSelection(providerID: "openai", modelID: "gpt-5")
        )

        XCTAssertEqual(session.id, "ses_1")
        let recorded = await transport.requests()
        let request = try XCTUnwrap(recorded.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/session")
        XCTAssertEqual(queryValue("directory", in: request), "/tmp/repository")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Basic b3BlbmNvZGU6c2VjcmV0"
        )
        let body = try jsonObject(request)
        XCTAssertEqual(body["title"] as? String, "AgentHub task")
        XCTAssertEqual(body["agent"] as? String, "build")
        XCTAssertEqual((body["model"] as? [String: Any])?["providerID"] as? String, "openai")
        XCTAssertEqual((body["model"] as? [String: Any])?["id"] as? String, "gpt-5")
    }

    func testPermissionReplyEncodesAlwaysAndMapsNotFoundToAlreadyResolved() async throws {
        let transport = RecordingOpenCodeHTTPTransport()
        await transport.enqueue(status: 200, body: Data("true".utf8))
        await transport.enqueue(status: 404, body: Data("{}".utf8))
        let client = makeClient(transport: transport)

        try await client.replyPermission(
            id: "per_1",
            reply: .always,
            message: nil,
            directory: "/tmp/repository"
        )
        let recorded = await transport.requests()
        let first = try XCTUnwrap(recorded.first)
        XCTAssertEqual(first.url?.path, "/permission/per_1/reply")
        XCTAssertEqual(try jsonObject(first)["reply"] as? String, "always")

        do {
            try await client.replyPermission(
                id: "per_1",
                reply: .once,
                message: nil,
                directory: "/tmp/repository"
            )
            XCTFail("expected already-resolved error")
        } catch {
            XCTAssertEqual(error as? OpenCodeHTTPError, .alreadyResolved)
        }
    }

    func testMessagesClampLimitToTwenty() async throws {
        let transport = RecordingOpenCodeHTTPTransport()
        await transport.enqueue(status: 200, body: Data("[]".utf8))
        let client = makeClient(transport: transport)

        _ = try await client.messages(
            sessionID: "ses_1",
            directory: "/tmp/repository",
            limit: 100
        )

        let recorded = await transport.requests()
        let request = try XCTUnwrap(recorded.first)
        XCTAssertEqual(queryValue("limit", in: request), "20")
    }

    func testHealthToleratesUnknownFieldsAndUnauthorizedIsTyped() async throws {
        let transport = RecordingOpenCodeHTTPTransport()
        await transport.enqueue(status: 200, body: try fixture(named: "health"))
        await transport.enqueue(status: 401, body: Data())
        let client = makeClient(transport: transport)

        let health = try await client.health()
        XCTAssertTrue(health.healthy)
        XCTAssertEqual(health.version, "1.18.10")

        do {
            _ = try await client.sessions(directory: nil)
            XCTFail("expected authentication error")
        } catch {
            XCTAssertEqual(error as? OpenCodeHTTPError, .authenticationRequired)
        }
    }

    private func makeClient(
        transport: RecordingOpenCodeHTTPTransport
    ) -> OpenCodeHTTPClient {
        OpenCodeHTTPClient(
            baseURL: URL(string: "http://127.0.0.1:41789")!,
            authorization: .none,
            transport: transport
        )
    }

    private func fixture(named name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/OpenCode/\(name).json")
        return try Data(contentsOf: url)
    }

    private func queryValue(_ name: String, in request: URLRequest) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == name }?
            .value
    }

    private func jsonObject(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
                as? [String: Any]
        )
    }
}

private actor RecordingOpenCodeHTTPTransport: OpenCodeHTTPTransport {
    private struct Stub: Sendable {
        let status: Int
        let body: Data
    }

    private var stubs: [Stub] = []
    private var recorded: [URLRequest] = []

    func enqueue(status: Int, body: Data) {
        stubs.append(Stub(status: status, body: body))
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recorded.append(request)
        let stub = stubs.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (stub.body, response)
    }

    func bytes(
        for request: URLRequest
    ) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        recorded.append(request)
        let stub = stubs.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (AsyncThrowingStream { continuation in
            continuation.yield(stub.body)
            continuation.finish()
        }, response)
    }

    func requests() -> [URLRequest] {
        recorded
    }
}
