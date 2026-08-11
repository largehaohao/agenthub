import XCTest
@testable import AgentHubDaemon

final class DaemonBootstrapTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertNotNil(AgentHubDaemonBootstrap.self)
    }
}
