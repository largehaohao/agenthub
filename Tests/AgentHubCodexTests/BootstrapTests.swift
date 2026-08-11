import XCTest
@testable import AgentHubCodex

final class CodexBootstrapTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertNotNil(AgentHubCodexBootstrap.self)
    }
}
