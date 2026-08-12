import Foundation
import XCTest
import AgentHubCore
@testable import AgentHubCursor

final class CursorAdapterConfigurationTests: XCTestCase {
    func testInstallHooksUsesInstaller() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let hooksURL = dir.appendingPathComponent("hooks.json")
        let helper = dir.appendingPathComponent("agenthub-cursor-hook")
        try Data().write(to: helper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helper.path
        )
        let installer = CursorHookInstaller(hooksURL: hooksURL, executableURL: helper)
        let adapter = CursorAdapter(accountID: "default", hookInstaller: installer)

        let components = try await adapter.configure(.installHooks)
        XCTAssertEqual(components.count, 1)
        XCTAssertEqual(components.first?.component, "hooks")
        XCTAssertEqual(components.first?.available, true)

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as! [String: Any]
        let hooks = root["hooks"] as! [String: Any]
        XCTAssertNotNil(hooks["sessionStart"])
    }

    func testAuthorizeQuotaAccessIsUnsupportedUntilTask9() async {
        let adapter = CursorAdapter(accountID: "default")
        do {
            _ = try await adapter.configure(.authorizeQuotaAccess)
            XCTFail("expected unsupported")
        } catch {
            XCTAssertEqual(error as? CursorAdapterError, .unsupportedCapability)
        }
    }
}
