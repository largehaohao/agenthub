import Foundation
import XCTest
import AgentHubCore
import AgentHubPersistence
import AgentHubTestSupport
@testable import AgentHubCodex
@testable import AgentHubDaemon

final class PrivacyTests: XCTestCase {
    func testProviderSecretIsAbsentFromDatabaseAndRedactedDiagnostics() async throws {
        struct SecretProviderError: Error, CustomStringConvertible {
            let description: String
        }

        let secret = "sk-agenthub-never-persist-this"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentHubPrivacy-\(UUID().uuidString)")
        let databaseURL = directory.appendingPathComponent("agenthub.sqlite")
        let store = try AgentHubStore(databaseURL: databaseURL)
        let adapter = TestAdapter()
        await adapter.setSendError(SecretProviderError(description: secret))
        let service = HandoffService(store: store, adapters: [.codex: adapter])
        var envelope = MessageEnvelope.fixture()
        envelope.createdAt = Date()
        envelope.expiresAt = envelope.createdAt.addingTimeInterval(60)
        let source = AgentSession.fixture(id: envelope.sourceSessionID)
        let target = AgentSession.fixture(
            id: envelope.targetSessionID,
            nativeID: "privacy-target",
            status: .idle
        )
        try await store.apply(.sessionUpserted(source))
        try await store.apply(.sessionUpserted(target))

        do {
            try await service.submit(envelope, target: target, pendingRequests: [])
            XCTFail("Expected provider failure")
        } catch is SecretProviderError {
            // The immediate caller may handle the typed provider error.
        }

        let diagnostic = CodexProcess.redact("Authorization: Bearer \(secret) \(secret)")
        let logURL = directory.appendingPathComponent("agenthub.log")
        try diagnostic.write(to: logURL, atomically: true, encoding: String.Encoding.utf8)

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        let secretBytes = Data(secret.utf8)
        for file in files where (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            let contents = try Data(contentsOf: file)
            XCTAssertNil(contents.range(of: secretBytes), file.lastPathComponent)
        }
    }
}
