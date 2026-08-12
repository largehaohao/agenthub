import Foundation
import XCTest
import AgentHubCore
import AgentHubOpenCodeTestSupport
@testable import AgentHubOpenCode

final class FakeOpenCodeServerTests: XCTestCase {
    func testFakeServerSupportsCRUDSSEAndRedactedRequestRecording() async throws {
        let server = try await FakeOpenCodeServer.start()
        addTeardownBlock { await server.stop() }
        let client = OpenCodeHTTPClient(
            baseURL: try XCTUnwrap(URL(string: server.baseURL)),
            authorization: .basic(username: "opencode", password: "fake-secret")
        )

        let health = try await client.health()
        XCTAssertTrue(health.healthy)
        let created = try await client.createSession(
            directory: "/tmp/fake-opencode",
            title: "Fake contract",
            agent: nil,
            model: nil
        )
        let fetched = try await client.session(id: created.id, directory: created.directory)
        XCTAssertEqual(fetched.id, created.id)

        let stream = await client.events(directory: nil)
        let eventTask = Task { () throws -> OpenCodeEvent? in
            for try await event in stream { return event }
            return nil
        }
        try await waitUntil {
            await server.requests().contains { $0.path == "/event" }
        }
        await server.emitEvent(type: "session.updated")
        let event = try await eventTask.value
        XCTAssertEqual(event?.type, "session.updated")

        try await client.deleteSession(id: created.id, directory: created.directory)
        let requests = await server.requests()
        XCTAssertTrue(requests.allSatisfy { request in
            !request.body.contains("fake-secret")
        })
        XCTAssertTrue(requests.contains { $0.authorizationPresent })
    }

    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw FakeContractError.timedOut
    }
}

private enum FakeContractError: Error { case timedOut }
