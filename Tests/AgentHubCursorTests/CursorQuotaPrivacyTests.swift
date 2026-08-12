import Foundation
import XCTest
import AgentHubCore
@testable import AgentHubCursor

final class CursorQuotaPrivacyTests: XCTestCase {
    func testEncodedSnapshotNeverContainsTokenSubstring() async throws {
        let token = "secret-token-value-xyz"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("state.vscdb")
        try writeTokenDatabase(at: databaseURL, token: token)

        FixtureURLProtocol.fixtureData = try cursorFixture("usage-period")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let defaults = UserDefaults(suiteName: "AgentHubCursorPrivacy.\(UUID().uuidString)")!
        let auth = CursorQuotaAuthStore(defaults: defaults)
        let collector = CursorQuotaCollector(
            auth: auth,
            reader: CursorLoginSessionReader(databaseURL: databaseURL),
            client: CursorQuotaClient(
                accountID: "default",
                session: session,
                now: { Date(timeIntervalSince1970: 1_700_000_000) }
            ),
            pollInterval: .seconds(3_600)
        )
        let adapter = CursorAdapter(accountID: "default", quotaCollector: collector)

        _ = try await adapter.configure(.authorizeQuotaAccess)
        let snapshot = try await adapter.reconcile()
        var state = AgentHubState.empty
        for window in snapshot.quotas {
            state.quotas[window.id] = window
        }

        let encoded = try JSONEncoder.agentHub.encode(state)
        let encodedText = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(encodedText.contains(token))
    }

    func testQuotaClientNeverIncludesTokenInQuotaWindows() async throws {
        let token = "secret-token-value-xyz"
        FixtureURLProtocol.fixtureData = try cursorFixture("usage-period")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let client = CursorQuotaClient(accountID: "default", session: session)
        let windows = try await client.fetchWindows(token: token)
        let encoded = try JSONEncoder.agentHub.encode(windows)
        let encodedText = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(encodedText.contains(token))
    }

    private func cursorFixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Cursor/\(name).json")
        return try Data(contentsOf: url)
    }

    private func writeTokenDatabase(at url: URL, token: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "CursorQuotaPrivacyTests", code: 1)
        }
        defer { sqlite3_close(database) }

        guard sqlite3_exec(
            database,
            "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)",
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            throw NSError(domain: "CursorQuotaPrivacyTests", code: 2)
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "INSERT INTO ItemTable (key, value) VALUES (?, ?)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw NSError(domain: "CursorQuotaPrivacyTests", code: 3)
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, CursorLoginSessionReader.accessTokenItemKey, -1, nil)
        sqlite3_bind_text(statement, 2, token, -1, nil)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(domain: "CursorQuotaPrivacyTests", code: 4)
        }
    }
}

private final class FixtureURLProtocol: URLProtocol {
    nonisolated(unsafe) static var fixtureData: Data?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == CursorQuotaClient.usageSummaryURL.host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let data = Self.fixtureData ?? Data()
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

import SQLite3
