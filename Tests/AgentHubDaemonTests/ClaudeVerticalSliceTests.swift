import Foundation
import XCTest
import AgentHubCore
import AgentHubIPC
import AgentHubPersistence
import AgentHubTestSupport
@testable import AgentHubDaemon

final class ClaudeVerticalSliceTests: XCTestCase {
    func testClaudeHookReachesTheAdapterThroughTheDaemonAPI() async throws {
        let context = try await makeContext()

        let reply = await context.api.handle(.ingestProviderHook(hook()))

        XCTAssertEqual(reply, .completed)
        let ingested = await context.adapter.ingestedHooks()
        XCTAssertEqual(ingested.count, 1)
        XCTAssertEqual(ingested.first?.provider, .claude)
    }

    func testHookForAMismatchedProviderIsRejectedBeforeIngestion() async throws {
        let context = try await makeContext()
        let foreign = try ProviderHookEnvelope(
            provider: .codex,
            rawJSON: Data("{}".utf8),
            sourcePID: 41,
            ancestors: [],
            observedAt: Date(timeIntervalSince1970: 1)
        )

        let reply = await context.api.handle(.ingestProviderHook(foreign))

        guard case .failure = reply else {
            return XCTFail("expected a mismatched provider hook to fail")
        }
        let ingested = await context.adapter.ingestedHooks()
        XCTAssertTrue(ingested.isEmpty)
    }

    func testConfigureProviderReportsComponentStatusFromTheAdapter() async throws {
        let context = try await makeContext(start: true)
        try await context.store.apply(.componentUpserted(
            ProviderComponentStatus(
                provider: .claude,
                component: "hooks",
                available: true,
                version: "2.1.228",
                path: "/tmp/agenthub-claude-hook",
                message: nil,
                changedAt: Date(timeIntervalSince1970: 1)
            )
        ))
        try await context.coordinator.refreshFromStore()

        let reply = await context.api.handle(.configureProvider(.claude, .installHooks))

        guard case .components(let components) = reply else {
            return XCTFail("expected component status")
        }
        XCTAssertEqual(components.first?.component, "hooks")
        let actions = await context.adapter.configureActions()
        XCTAssertEqual(actions, [.installHooks])
    }

    func testNativeRequestRemainsPendingUntilAppStartsMatchingPlan() async throws {
        let context = try await makeContext()
        let request = PendingRequest.fixture(state: .pending, provider: .claude)
        try await context.store.apply(.requestUpserted(request))
        let plan = plan(for: request.id)
        await context.adapter.setResolutionRoute(.native(plan))

        let result = try await context.requests.resolve(id: request.id, decision: .accept)

        guard case .native(let returned) = result else {
            return XCTFail("expected a native interaction plan")
        }
        // The request must not advance until the app proves it acted on the UI.
        var snapshot = try await context.store.snapshot()
        XCTAssertEqual(snapshot.requests[request.id]?.state, .pending)

        try await context.requests.nativeInteractionStarted(
            requestID: request.id,
            planID: returned.id
        )

        snapshot = try await context.store.snapshot()
        XCTAssertEqual(snapshot.requests[request.id]?.state, .resolving)
    }

    func testNativeInteractionWithAMismatchedPlanIsRejected() async throws {
        let context = try await makeContext()
        let request = PendingRequest.fixture(state: .pending, provider: .claude)
        try await context.store.apply(.requestUpserted(request))
        await context.adapter.setResolutionRoute(.native(plan(for: request.id)))
        _ = try await context.requests.resolve(id: request.id, decision: .accept)

        do {
            try await context.requests.nativeInteractionStarted(
                requestID: request.id,
                planID: UUID()
            )
            XCTFail("expected a mismatched plan to be rejected")
        } catch {
            XCTAssertEqual(error as? RequestServiceError, .notFound)
        }

        let snapshot = try await context.store.snapshot()
        XCTAssertEqual(snapshot.requests[request.id]?.state, .pending)
    }

    func testProviderRouteStillResolvesThroughTheAdapter() async throws {
        let context = try await makeContext()
        let request = PendingRequest.fixture(state: .pending, provider: .claude)
        try await context.store.apply(.requestUpserted(request))

        let result = try await context.requests.resolve(id: request.id, decision: .accept)

        guard case .resolved = result else {
            return XCTFail("expected a provider-resolved outcome")
        }
        let snapshot = try await context.store.snapshot()
        XCTAssertEqual(snapshot.requests[request.id]?.state, .resolved)
    }

    // MARK: - Helpers

    private struct Context {
        let store: AgentHubStore
        let adapter: HookTestAdapter
        let coordinator: Coordinator
        let requests: RequestService
        let api: DaemonAPI
    }

    private func makeContext(start: Bool = false) async throws -> Context {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeVerticalSliceTests-\(UUID().uuidString)")
            .appendingPathComponent("agenthub.sqlite")
        let store = try AgentHubStore(databaseURL: url)
        let adapter = HookTestAdapter()
        let adapters: [Provider: any AgentAdapter] = [.claude: adapter]
        let coordinator = Coordinator(store: store, adapters: adapters)
        let requests = RequestService(store: store, adapters: adapters)
        let handoffs = HandoffService(store: store, adapters: adapters)

        if start {
            try await coordinator.start()
        }
        return Context(
            store: store,
            adapter: adapter,
            coordinator: coordinator,
            requests: requests,
            api: DaemonAPI(coordinator: coordinator, requests: requests, handoffs: handoffs)
        )
    }

    private func hook() -> ProviderHookEnvelope {
        try! ProviderHookEnvelope(
            provider: .claude,
            rawJSON: Data("{\"hook_event_name\":\"SessionStart\"}".utf8),
            sourcePID: 41,
            ancestors: [],
            observedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func plan(for requestID: UUID) -> NativeInteractionPlan {
        NativeInteractionPlan(
            id: UUID(),
            provider: .claude,
            requestID: requestID,
            bundleID: "com.anthropic.claudefordesktop",
            windowHint: nil,
            sessionNativeID: "abc123",
            promptFingerprint: "fingerprint",
            operation: .choose(label: "Yes")
        )
    }
}
