import XCTest
@testable import AgentHubCore

final class BootstrapTests: XCTestCase {
    func testLibraryExportsVersion() {
        XCTAssertEqual(AgentHubCoreVersion.current, "0.1.0")
    }
}
