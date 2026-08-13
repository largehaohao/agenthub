import Foundation
import XCTest
@testable import AgentHubQuota

final class CursorQuotaPrivacyTests: XCTestCase {
    /// The token reaches the collector and the network, and must not survive
    /// into anything that could be rendered or written down.
    func testCollectorWindowsNeverContainTheToken() async throws {
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
        let collector = CursorQuotaCollector(
            auth: CursorQuotaAuthStore(defaults: defaults),
            reader: CursorLoginSessionReader(databaseURL: databaseURL),
            client: CursorQuotaClient(
                accountID: "default",
                session: session,
                now: { Date(timeIntervalSince1970: 1_700_000_000) }
            ),
            pollInterval: .seconds(3_600),
            resumePollingOnInit: false
        )

        await collector.authorize()
        let windows = try await collector.refresh()

        let encoded = try JSONEncoder().encode(windows)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(token))
        XCTAssertFalse(windows.isEmpty, "the fixture should produce windows")
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
        let encoded = try JSONEncoder().encode(windows)
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

        // SQLITE_TRANSIENT: sqlite must copy, because the bridged C strings do
        // not outlive this call.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(
            statement, 1, CursorLoginSessionReader.accessTokenItemKey, -1, transient
        )
        sqlite3_bind_text(statement, 2, token, -1, transient)
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
