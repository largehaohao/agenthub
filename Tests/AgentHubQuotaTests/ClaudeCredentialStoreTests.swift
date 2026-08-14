import XCTest
@testable import AgentHubQuota

private func blob(name: String, expiresAt: Date?) -> Data {
    var oauth: [String: Any] = ["accessToken": name, "refreshToken": "\(name)-refresh"]
    if let expiresAt { oauth["expiresAt"] = expiresAt.timeIntervalSince1970 * 1_000 }
    return try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
}

private final class Stub: ClaudeCredentialStore, @unchecked Sendable {
    var data: Data?
    private(set) var saved: Data?
    init(_ data: Data?) { self.data = data }
    func load() -> Data? { data }
    func save(_ new: Data) -> Bool { saved = new; data = new; return true }
}

final class ClaudeCredentialStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    /// The login Keychain item is written once at sign-in and can be left
    /// holding a dead token long after Claude Code has moved on. Preferring it
    /// would report "signed out" on a Mac that is signed in.
    func testTheLaterExpiryWins() {
        let stale = Stub(blob(name: "stale", expiresAt: now.addingTimeInterval(-86_400)))
        let live = Stub(blob(name: "live", expiresAt: now.addingTimeInterval(3_600)))

        let combined = ClaudeCredentialStores([stale, live])

        XCTAssertEqual(combined.load(), live.data)
    }

    func testOrderDoesNotDecideTheWinner() {
        let stale = Stub(blob(name: "stale", expiresAt: now.addingTimeInterval(-86_400)))
        let live = Stub(blob(name: "live", expiresAt: now.addingTimeInterval(3_600)))

        XCTAssertEqual(ClaudeCredentialStores([live, stale]).load(), live.data)
        XCTAssertEqual(ClaudeCredentialStores([stale, live]).load(), live.data)
    }

    /// Writing the renewed token into the stale store would leave the live one
    /// untouched and the refresh would repeat on every poll.
    func testTheRenewedTokenIsWrittenToTheStoreItCameFrom() {
        let stale = Stub(blob(name: "stale", expiresAt: now.addingTimeInterval(-86_400)))
        let live = Stub(blob(name: "live", expiresAt: now.addingTimeInterval(3_600)))
        let combined = ClaudeCredentialStores([stale, live])

        XCTAssertTrue(combined.save(Data("renewed".utf8)))

        XCTAssertEqual(live.saved, Data("renewed".utf8))
        XCTAssertNil(stale.saved)
    }

    func testUnreadableAndMalformedStoresAreSkipped() {
        let empty = Stub(nil)
        let junk = Stub(Data("not json".utf8))
        let live = Stub(blob(name: "live", expiresAt: now))

        XCTAssertEqual(ClaudeCredentialStores([empty, junk, live]).load(), live.data)
    }

    func testNoCredentialAnywhereReadsAsNothing() {
        let combined = ClaudeCredentialStores([Stub(nil), Stub(nil)])

        XCTAssertNil(combined.load())
        XCTAssertFalse(combined.save(Data("renewed".utf8)))
    }

    func testFileStoreRoundTripsAndStaysOwnerOnly() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).json")
        let original = blob(name: "live", expiresAt: now)
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = ClaudeCredentialFileStore(url: url)

        XCTAssertEqual(store.load(), original)
        XCTAssertTrue(store.save(blob(name: "renewed", expiresAt: now)))
        XCTAssertEqual(store.load(), blob(name: "renewed", expiresAt: now))

        // An atomic write replaces the file, so the mode has to be reapplied.
        let mode = try FileManager.default
            .attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o600)
    }

    /// AgentHub renews a credential Claude Code owns; it must never bring one
    /// into existence.
    func testFileStoreNeverCreatesAMissingFile() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).json")
        let store = ClaudeCredentialFileStore(url: url)

        XCTAssertFalse(store.save(blob(name: "invented", expiresAt: now)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

final class ClaudeCredentialBlobTests: XCTestCase {
    func testParsesTokensAndExpiry() throws {
        let payload = """
        {"claudeAiOauth":{"accessToken":"tok-123","refreshToken":"r",
        "expiresAt":1786631766712,"subscriptionType":"pro"}}
        """

        let blob = try XCTUnwrap(ClaudeCredentialBlob(data: Data(payload.utf8)))

        XCTAssertEqual(blob.accessToken, "tok-123")
        XCTAssertEqual(blob.refreshToken, "r")
        XCTAssertEqual(
            try XCTUnwrap(blob.expiresAt).timeIntervalSince1970,
            1_786_631_766.712,
            accuracy: 0.01
        )
        XCTAssertFalse(blob.expiresSoon(now: Date(timeIntervalSince1970: 1_786_000_000)))
        XCTAssertTrue(blob.expiresSoon(now: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    func testMalformedCredentialIsRejected() {
        XCTAssertNil(ClaudeCredentialBlob(data: Data("{}".utf8)))
        XCTAssertNil(ClaudeCredentialBlob(data: Data("not json".utf8)))
    }

    /// An empty string is how Claude Code marks a token it has given up on, and
    /// must not be handed out as if it were usable.
    func testEmptyTokensReadAsAbsent() throws {
        let payload = #"{"claudeAiOauth":{"accessToken":"","refreshToken":""}}"#

        let blob = try XCTUnwrap(ClaudeCredentialBlob(data: Data(payload.utf8)))

        XCTAssertNil(blob.accessToken)
        XCTAssertNil(blob.refreshToken)
    }
}
