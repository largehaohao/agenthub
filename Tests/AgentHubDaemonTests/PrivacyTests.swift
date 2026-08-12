import Foundation
import XCTest
import AgentHubCore
import AgentHubPersistence
import AgentHubTestSupport
@testable import AgentHubCodex
@testable import AgentHubDaemon
@testable import AgentHubOpenCode

final class PrivacyTests: XCTestCase {
    func testOpenCodeSecretsAnswersAndRenderedHandoffsAreAbsentFromPersistence() async throws {
        let endpointPassword = "opencode-password-never-persist"
        let authorization = "Basic b3BlbmNvZGU6bmV2ZXItcGVyc2lzdA=="
        let questionFreeText = "private-question-answer-never-persist"
        let credentialReference = "keychain-reference-safe-to-persist"
        let baseURL = "http://127.0.0.1:41789"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentHubOpenCodePrivacy-\(UUID().uuidString)")
        let databaseURL = directory.appendingPathComponent("agenthub.sqlite")
        let store = try AgentHubStore(databaseURL: databaseURL)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let endpoint = ProviderEndpoint(
            id: "manual-private",
            provider: .openCode,
            origin: .manual,
            baseURL: baseURL,
            credentialReference: credentialReference,
            connected: true,
            lastSeenAt: now
        )
        try await store.apply(.endpointUpserted(endpoint))
        try await store.apply(.endpointUpserted(ProviderEndpoint(
            id: "managed-private",
            provider: .openCode,
            origin: .managed,
            baseURL: "http://127.0.0.1:41790",
            connected: true,
            lastSeenAt: now
        )))

        let source = AgentSession.fixture(nativeID: "privacy-source", status: .idle)
        let target = AgentSession.fixture(id: UUID(), nativeID: "privacy-target", status: .idle)
        var envelope = MessageEnvelope.fixture()
        envelope.sourceSessionID = source.id
        envelope.targetSessionID = target.id
        envelope.turns = [.init(
            id: "visible-turn",
            role: "assistant",
            text: "A bounded visible turn",
            createdAt: now
        )]
        envelope.userNote = "Continue safely"
        let renderedHandoff = HandoffRouter.render(envelope, source: source)
        try await store.apply(.envelopeUpserted(envelope))
        let request = PendingRequest(
            id: UUID(),
            provider: .openCode,
            providerRequestID: "private-question",
            sessionID: target.id,
            threadID: "privacy-target",
            kind: .choice,
            title: "Private question",
            detail: "Answer without persistence",
            allowedActions: ["answer"],
            fields: [.init(id: "0", prompt: "Private answer", allowsFreeText: true)],
            state: .pending,
            reliability: .l1,
            createdAt: now
        )
        try await store.apply(.requestUpserted(request))
        try await store.apply(.requestResolved(id: request.id, outcome: "answered"))

        let diagnostic = OpenCodeDiagnosticRing.redact(
            "Authorization: \(authorization) password=\(endpointPassword)"
        )
        let logURL = directory.appendingPathComponent("agenthub.log")
        try diagnostic.write(to: logURL, atomically: true, encoding: .utf8)

        let persisted = try combinedRegularFileContents(in: directory)
        for forbidden in [
            endpointPassword,
            authorization,
            questionFreeText,
            renderedHandoff,
        ] {
            XCTAssertNil(persisted.range(of: Data(forbidden.utf8)), forbidden)
        }
        XCTAssertNotNil(persisted.range(of: Data(credentialReference.utf8)))
        let snapshot = try await store.snapshot()
        XCTAssertNil(snapshot.endpoints["managed-private"])
        XCTAssertEqual(snapshot.endpoints[endpoint.id]?.credentialReference, credentialReference)
        XCTAssertEqual(snapshot.endpoints[endpoint.id]?.baseURL, baseURL)
    }

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

    private func combinedRegularFileContents(in directory: URL) throws -> Data {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        return try files.reduce(into: Data()) { combined, file in
            if (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
                combined.append(try Data(contentsOf: file))
            }
        }
    }
}
