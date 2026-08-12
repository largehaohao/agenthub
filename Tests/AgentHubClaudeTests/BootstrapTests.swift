import XCTest
@testable import AgentHubClaude

final class BootstrapTests: XCTestCase {
    func testModuleIsLinked() {
        XCTAssertNotNil(AgentHubClaudeBootstrap.self)
    }
}
