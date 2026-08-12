import Foundation
import XCTest
import AgentHubCore
@testable import AgentHubCursor

final class CursorQuotaCollectorTests: XCTestCase {
    private var fixtureSession: URLSession!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "AgentHubCursorQuotaTests.\(UUID().uuidString)")!
        FixtureURLProtocol.fixtureData = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        fixtureSession = URLSession(configuration: configuration)
    }

    override func tearDown() {
        fixtureSession.invalidateAndCancel()
        fixtureSession = nil
        defaults = nil
        FixtureURLProtocol.fixtureData = nil
        super.tearDown()
    }

    func testCollectorEmitsWindowsFromFixtureClient() async throws {
        FixtureURLProtocol.fixtureData = try cursorFixture("usage-period")
        let reader = try makeReader(token: "fixture-token")
        let auth = CursorQuotaAuthStore(defaults: defaults)
        auth.authorize()

        let client = CursorQuotaClient(
            accountID: "default",
            session: fixtureSession,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let collector = CursorQuotaCollector(
            auth: auth,
            reader: reader,
            client: client,
            pollInterval: .seconds(3_600),
            resumePollingOnInit: false
        )

        let windows = try await collector.refresh()
        XCTAssertFalse(windows.isEmpty)
        XCTAssertEqual(windows.first?.source, "cursor-dashboard")
        XCTAssertEqual(Set(windows.map(\.windowID)), Set(["auto", "api", "total"]))
    }

    func testRevokeClearsWindowsAndDisablesCollection() async throws {
        FixtureURLProtocol.fixtureData = try cursorFixture("usage-period")
        let reader = try makeReader(token: "fixture-token")
        let auth = CursorQuotaAuthStore(defaults: defaults)
        auth.authorize()

        let client = CursorQuotaClient(
            accountID: "default",
            session: fixtureSession,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let collector = CursorQuotaCollector(
            auth: auth,
            reader: reader,
            client: client,
            pollInterval: .seconds(3_600),
            resumePollingOnInit: false
        )

        _ = try await collector.refresh()
        let windowsAfterRefresh = await collector.currentWindows()
        XCTAssertFalse(windowsAfterRefresh.isEmpty)
        let authorizedBeforeRevoke = await collector.isAuthorized
        XCTAssertTrue(authorizedBeforeRevoke)

        await collector.revoke()
        let windowsAfterRevoke = await collector.currentWindows()
        XCTAssertTrue(windowsAfterRevoke.isEmpty)
        let authorizedAfterRevoke = await collector.isAuthorized
        XCTAssertFalse(authorizedAfterRevoke)

        let status = await collector.quotaComponentStatus()
        XCTAssertEqual(status.component, "quota")
        XCTAssertEqual(status.available, false)
    }

    func testRefreshRequiresAuthorization() async {
        let reader = try? makeReader(token: "fixture-token")
        let auth = CursorQuotaAuthStore(defaults: defaults)
        let client = CursorQuotaClient(accountID: "default", session: fixtureSession)
        let collector = CursorQuotaCollector(
            auth: auth,
            reader: reader ?? CursorLoginSessionReader(databaseURL: URL(fileURLWithPath: "/dev/null")),
            client: client
        )

        do {
            _ = try await collector.refresh()
            XCTFail("expected not authorized")
        } catch {
            XCTAssertEqual(error as? CursorQuotaCollectorError, .notAuthorized)
        }
    }

    func testClientOmitsWindowsWithoutBillingCycleEnd() throws {
        let payload = Data("""
        {"membershipType":"pro","individualUsage":{"plan":{"autoPercentUsed":10}}}
        """.utf8)

        let windows = try CursorQuotaClient.decodeWindows(
            payload,
            accountID: "default",
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertTrue(windows.isEmpty)
    }

    func testClientSkipsInvalidPercentages() throws {
        let payload = Data("""
        {"billingCycleStart":"2026-04-02T14:11:55.000Z",
         "billingCycleEnd":"2026-05-02T14:11:55.000Z",
         "individualUsage":{"plan":{"autoPercentUsed":900,"apiPercentUsed":10}}}
        """.utf8)

        let windows = try CursorQuotaClient.decodeWindows(
            payload,
            accountID: "default",
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(windows.map(\.windowID), ["api"])
    }

    private func makeReader(token: String) throws -> CursorLoginSessionReader {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("state.vscdb")
        try writeTokenDatabase(at: databaseURL, token: token)
        return CursorLoginSessionReader(databaseURL: databaseURL)
    }

    private func writeTokenDatabase(at url: URL, token: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "CursorQuotaCollectorTests", code: 1)
        }
        defer { sqlite3_close(database) }

        guard sqlite3_exec(
            database,
            "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)",
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            throw NSError(domain: "CursorQuotaCollectorTests", code: 2)
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "INSERT INTO ItemTable (key, value) VALUES (?, ?)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw NSError(domain: "CursorQuotaCollectorTests", code: 3)
        }
        defer { sqlite3_finalize(statement) }

        let key = CursorLoginSessionReader.accessTokenItemKey
        try key.withCString { keyPointer in
            try token.withCString { tokenPointer in
                guard sqlite3_bind_text(statement, 1, keyPointer, -1, nil) == SQLITE_OK,
                      sqlite3_bind_text(statement, 2, tokenPointer, -1, nil) == SQLITE_OK,
                      sqlite3_step(statement) == SQLITE_DONE else {
                    throw NSError(domain: "CursorQuotaCollectorTests", code: 4)
                }
            }
        }
    }

    private func cursorFixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Cursor/\(name).json")
        return try Data(contentsOf: url)
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
