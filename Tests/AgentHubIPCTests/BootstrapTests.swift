import XCTest
@testable import AgentHubIPC

final class IPCBootstrapTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertNotNil(AgentHubIPCBootstrap.self)
    }
}
