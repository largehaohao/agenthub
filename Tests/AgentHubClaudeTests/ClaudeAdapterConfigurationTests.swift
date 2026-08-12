import Foundation
import XCTest
import AgentHubCore
@testable import AgentHubClaude

final class ClaudeAdapterConfigurationTests: XCTestCase {
    private var directory: URL!
    private var settingsURL: URL!
    private let executableURL = URL(fileURLWithPath: "/tmp/agenthub/bin/agenthub-claude-hook")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agenthub-configure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        settingsURL = directory.appendingPathComponent("settings.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testInstallHooksActuallyWritesUserSettings() async throws {
        let adapter = makeAdapter()

        try await adapter.configure(.installHooks)

        let settings = try readSettings()
        XCTAssertFalse(
            agentHubCommands(in: settings, event: "SessionStart").isEmpty,
            "configure(.installHooks) must reach ClaudeHookInstaller"
        )
    }

    func testUninstallHooksRemovesThem() async throws {
        let adapter = makeAdapter()
        try await adapter.configure(.installHooks)

        try await adapter.configure(.uninstallHooks)

        let settings = try readSettings()
        XCTAssertTrue(agentHubCommands(in: settings, event: "SessionStart").isEmpty)
    }

    func testConfigureReportsHookComponentStatus() async throws {
        let adapter = makeAdapter()

        let before = try await adapter.configure(.refreshComponents)
        XCTAssertEqual(before.first { $0.component == "hooks" }?.available, false)

        let after = try await adapter.configure(.installHooks)
        let hooks = try XCTUnwrap(after.first { $0.component == "hooks" })
        XCTAssertTrue(hooks.available)
        XCTAssertEqual(hooks.provider, .claude)
        XCTAssertEqual(hooks.path, executableURL.path)
    }

    func testComponentStatusIsPublishedAsAnEvent() async throws {
        let adapter = makeAdapter()
        let events = await adapter.eventStream()

        let collected = Task {
            var seen: [ProviderComponentStatus] = []
            for await event in events {
                if case .componentUpserted(let status) = event {
                    seen.append(status)
                    if seen.count == 1 { return seen }
                }
            }
            return seen
        }

        _ = try await adapter.configure(.installHooks)
        let seen = await collected.value

        XCTAssertEqual(seen.first?.component, "hooks")
    }

    func testConfigureWithoutAnInstallerReportsUnavailableRatherThanFailing() async throws {
        let adapter = ClaudeAdapter(accountID: "personal")

        let components = try await adapter.configure(.refreshComponents)

        XCTAssertEqual(components.first { $0.component == "hooks" }?.available, false)
    }

    private func makeAdapter() -> ClaudeAdapter {
        ClaudeAdapter(
            accountID: "personal",
            hookInstaller: ClaudeHookInstaller(
                settingsURL: settingsURL,
                executableURL: executableURL,
                now: { Date(timeIntervalSince1970: 1) }
            ),
            now: { Date(timeIntervalSince1970: 1) }
        )
    }

    private func readSettings() throws -> [String: Any] {
        let data = try Data(contentsOf: settingsURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func agentHubCommands(in settings: [String: Any], event: String) -> [String] {
        guard let hooks = settings["hooks"] as? [String: Any],
              let matchers = hooks[event] as? [[String: Any]] else { return [] }
        return matchers
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
            .filter { ClaudeHookInstaller.executablePath(fromCommand: $0) == executableURL.path }
    }
}
