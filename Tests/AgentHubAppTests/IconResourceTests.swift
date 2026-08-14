import AppKit
import XCTest
@testable import AgentHubApp

@MainActor
final class IconResourceTests: XCTestCase {
    func testMenuBarQAssetIsPresentInTheApplicationBundle() throws {
        let image = try XCTUnwrap(
            NSImage(named: "MenuBarQ"),
            "MenuBarQ must be compiled into the AgentHub application bundle"
        )

        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }
}
