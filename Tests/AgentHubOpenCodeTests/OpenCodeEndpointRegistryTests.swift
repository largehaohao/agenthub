import Foundation
import XCTest
import AgentHubCore
@testable import AgentHubOpenCode

final class OpenCodeEndpointRegistryTests: XCTestCase {
    func testSameSessionAcrossEndpointsHasStableIdentityAndMergedSurfaces() async {
        let registry = OpenCodeEndpointRegistry()
        let desktop = endpoint(id: "desktop", origin: .desktop)
        let tui = endpoint(id: "tui", origin: .tui)
        await registry.upsert(desktop)
        await registry.upsert(tui)
        await registry.observe(
            sessionID: "ses_shared",
            directory: "/repo",
            endpointID: desktop.id,
            at: date(10)
        )
        await registry.observe(
            sessionID: "ses_shared",
            directory: "/repo",
            endpointID: tui.id,
            at: date(20)
        )

        let surfaces = await registry.surfaces(sessionID: "ses_shared")
        let route = await registry.route(
            sessionID: "ses_shared",
            directory: "/repo",
            operation: .jump
        )

        XCTAssertEqual(surfaces, [.desktop, .tui])
        XCTAssertEqual(route?.id, tui.id)
        XCTAssertEqual(
            stableOpenCodeUUID(accountID: "local-default", nativeID: "ses_shared"),
            stableOpenCodeUUID(accountID: "local-default", nativeID: "ses_shared")
        )
    }

    func testCommandNeverRoutesByDirectoryAlone() async {
        let registry = OpenCodeEndpointRegistry()
        let desktop = endpoint(id: "desktop", origin: .desktop)
        await registry.upsert(desktop)
        await registry.observe(
            sessionID: "ses_other",
            directory: "/repo",
            endpointID: desktop.id,
            at: date(20)
        )

        let route = await registry.route(
            sessionID: "ses_missing",
            directory: "/repo",
            operation: .send
        )

        XCTAssertNil(route)
    }

    func testManagedRouteWinsForCommandsAndNativeRouteWinsForJump() async {
        let registry = OpenCodeEndpointRegistry()
        let managed = endpoint(id: "managed", origin: .managed)
        let desktop = endpoint(id: "desktop", origin: .desktop)
        await registry.upsert(managed)
        await registry.upsert(desktop)
        for endpoint in [managed, desktop] {
            await registry.observe(
                sessionID: "ses_shared",
                directory: "/repo",
                endpointID: endpoint.id,
                at: date(endpoint.id == "managed" ? 10 : 20)
            )
        }

        let send = await registry.route(
            sessionID: "ses_shared",
            directory: "/repo",
            operation: .send
        )
        let jump = await registry.route(
            sessionID: "ses_shared",
            directory: "/repo",
            operation: .jump
        )

        XCTAssertEqual(send?.id, managed.id)
        XCTAssertEqual(jump?.id, desktop.id)
    }

    func testUnhealthyOrRemovedEndpointCannotRoute() async {
        let registry = OpenCodeEndpointRegistry()
        var desktop = endpoint(id: "desktop", origin: .desktop)
        await registry.upsert(desktop)
        await registry.observe(
            sessionID: "ses_shared",
            directory: "/repo",
            endpointID: desktop.id,
            at: date(10)
        )
        desktop.summary.connected = false
        await registry.upsert(desktop)

        var route = await registry.route(
            sessionID: "ses_shared",
            directory: "/repo",
            operation: .read
        )
        XCTAssertNil(route)

        await registry.remove(endpointID: desktop.id)
        route = await registry.route(
            sessionID: "ses_shared",
            directory: "/repo",
            operation: .jump
        )
        XCTAssertNil(route)
        let surfaces = await registry.surfaces(sessionID: "ses_shared")
        XCTAssertTrue(surfaces.isEmpty)
    }

    private func endpoint(
        id: String,
        origin: ProviderEndpointOrigin
    ) -> OpenCodeRuntimeEndpoint {
        OpenCodeRuntimeEndpoint(
            summary: ProviderEndpoint(
                id: id,
                provider: .openCode,
                origin: origin,
                baseURL: "http://127.0.0.1:41789",
                connected: true,
                version: "1.18.10",
                lastSeenAt: date(1)
            ),
            credential: .none,
            processID: nil,
            applicationBundleID: origin == .desktop ? "ai.opencode.desktop" : nil,
            terminalTTY: origin == .tui ? "ttys001" : nil
        )
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
