import Foundation
import XCTest
@testable import AgentHubSecurity

final class KeychainCredentialStoreTests: XCTestCase {
    func testSaveReadOverwriteAndDelete() throws {
        let store = KeychainCredentialStore(
            service: "com.agenthub.tests.\(UUID().uuidString)"
        )
        let reference = UUID().uuidString
        defer { try? store.delete(reference: reference) }

        try store.save("first-secret", reference: reference)
        XCTAssertEqual(try store.read(reference: reference), "first-secret")

        try store.save("second-secret", reference: reference)
        XCTAssertEqual(try store.read(reference: reference), "second-secret")

        try store.delete(reference: reference)
        XCTAssertThrowsError(try store.read(reference: reference)) { error in
            XCTAssertEqual(error as? CredentialStoreError, .notFound)
        }
    }
}
