import XCTest
@testable import AgentHubPersistence

final class PersistenceBootstrapTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertNotNil(AgentHubPersistenceBootstrap.self)
    }
}
