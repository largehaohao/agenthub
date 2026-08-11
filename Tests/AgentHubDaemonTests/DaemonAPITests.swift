import XCTest
import AgentHubCore
import AgentHubIPC
import AgentHubPersistence
import AgentHubTestSupport
@testable import AgentHubDaemon

final class DaemonAPITests: XCTestCase {
    func testRepeatedLaunchRequestReturnsSameSessionIDAndLaunchesOnce() async throws {
        let store = try makeCoordinatorStore()
        let adapter = TestAdapter()
        let coordinator = Coordinator(store: store, adapters: [.codex: adapter])
        try await coordinator.start()
        let api = DaemonAPI(
            coordinator: coordinator,
            requests: RequestService(store: store, adapters: [.codex: adapter]),
            handoffs: HandoffService(store: store, adapters: [.codex: adapter])
        )
        let request = LaunchRequest.fixture(clientRequestID: "launch-1")

        let first = await api.handle(.launch(.codex, request))
        let second = await api.handle(.launch(.codex, request))

        XCTAssertEqual(first, second)
        let launchCount = await adapter.launchRequests.count
        XCTAssertEqual(launchCount, 1)
        await coordinator.stop()
    }

    func testConcurrentDuplicateLaunchRequestsShareInFlightLaunch() async throws {
        let store = try makeCoordinatorStore()
        let adapter = TestAdapter()
        await adapter.setLaunchDelay(.milliseconds(50))
        let coordinator = Coordinator(store: store, adapters: [.codex: adapter])
        try await coordinator.start()
        let api = DaemonAPI(
            coordinator: coordinator,
            requests: RequestService(store: store, adapters: [.codex: adapter]),
            handoffs: HandoffService(store: store, adapters: [.codex: adapter])
        )
        let request = LaunchRequest.fixture(clientRequestID: "concurrent-launch")

        async let first = api.handle(.launch(.codex, request))
        async let second = api.handle(.launch(.codex, request))
        let replies = await [first, second]

        XCTAssertEqual(replies[0], replies[1])
        let launchCount = await adapter.launchRequests.count
        XCTAssertEqual(launchCount, 1)
        await coordinator.stop()
    }

    func testGetSnapshotReturnsCoordinatorState() async throws {
        let store = try makeCoordinatorStore()
        let adapter = TestAdapter()
        let coordinator = Coordinator(store: store, adapters: [.codex: adapter])
        try await coordinator.start()
        let api = DaemonAPI(
            coordinator: coordinator,
            requests: RequestService(store: store, adapters: [.codex: adapter]),
            handoffs: HandoffService(store: store, adapters: [.codex: adapter])
        )

        let reply = await api.handle(.getSnapshot)

        guard case .snapshot(let state) = reply else {
            return XCTFail("snapshot command returned the wrong reply")
        }
        XCTAssertEqual(state.sessions.count, 1)
        await coordinator.stop()
    }

    func testEndpointCommandsUpdateCoordinatorState() async throws {
        let store = try makeCoordinatorStore()
        let adapter = TestAdapter()
        let adapters: [Provider: any AgentAdapter] = [.codex: adapter]
        let coordinator = Coordinator(store: store, adapters: adapters)
        try await coordinator.start()
        let api = DaemonAPI(
            coordinator: coordinator,
            requests: RequestService(store: store, adapters: adapters),
            handoffs: HandoffService(store: store, adapters: adapters)
        )
        let attachment = ProviderEndpointAttachment(
            provider: .codex,
            baseURL: "http://127.0.0.1:41789",
            credentialReference: "keychain-ref"
        )

        let attachedReply = await api.handle(.attachEndpoint(attachment))
        guard case .endpoint(let attached) = attachedReply else {
            return XCTFail("attachment did not return endpoint summary")
        }
        let stateAfterAttach = await coordinator.snapshot()
        XCTAssertEqual(stateAfterAttach.endpoints[attached.id], attached)

        let detachedReply = await api.handle(.detachEndpoint(provider: .codex, id: attached.id))
        let stateAfterDetach = await coordinator.snapshot()
        XCTAssertEqual(detachedReply, .completed)
        XCTAssertNil(stateAfterDetach.endpoints[attached.id])
        await coordinator.stop()
    }
}
