import XCTest
@testable import AgentHubQuota

/// An in-memory stand-in for the login Keychain.
private final class FakeStore: ClaudeCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private(set) var writes = 0
    var saveSucceeds = true

    init(_ data: Data?) { self.data = data }

    func load() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return data
    }

    func save(_ new: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard saveSucceeds else { return false }
        writes += 1
        data = new
        return true
    }

    var oauth: [String: Any] {
        let root = try! JSONSerialization.jsonObject(with: data!) as! [String: Any]
        return root["claudeAiOauth"] as! [String: Any]
    }
}

private let now = Date(timeIntervalSince1970: 1_000_000)

private func blob(
    accessToken: String = "old-access",
    refreshToken: String? = "old-refresh",
    expiresAt: Date?,
    extras: [String: Any] = ["subscriptionType": "pro"]
) -> Data {
    var oauth: [String: Any] = extras
    oauth["accessToken"] = accessToken
    if let refreshToken { oauth["refreshToken"] = refreshToken }
    if let expiresAt { oauth["expiresAt"] = expiresAt.timeIntervalSince1970 * 1_000 }
    return try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
}

private func tokenResponse(
    access: String = "new-access",
    refresh: String? = "new-refresh",
    expiresIn: Double = 28_800
) -> Data {
    var json: [String: Any] = ["access_token": access, "expires_in": expiresIn]
    if let refresh { json["refresh_token"] = refresh }
    return try! JSONSerialization.data(withJSONObject: json)
}

final class ClaudeTokenRefreshTests: XCTestCase {
    func testValidTokenIsUsedWithoutRefreshing() async {
        let store = FakeStore(blob(expiresAt: now.addingTimeInterval(3_600)))
        let refresher = ClaudeTokenRefresher(
            store: store,
            post: { _ in XCTFail("must not call the token endpoint"); return nil },
            now: { now }
        )

        let token = await refresher.token()

        XCTAssertEqual(token, "old-access")
        XCTAssertEqual(store.writes, 0)
    }

    func testExpiredTokenIsRenewedAndWrittenBack() async {
        let store = FakeStore(blob(expiresAt: now.addingTimeInterval(-60)))
        let refresher = ClaudeTokenRefresher(
            store: store,
            post: { _ in (tokenResponse(), 200) },
            now: { now }
        )

        let token = await refresher.token()

        XCTAssertEqual(token, "new-access")
        XCTAssertEqual(store.writes, 1)
        XCTAssertEqual(store.oauth["accessToken"] as? String, "new-access")
        XCTAssertEqual(store.oauth["refreshToken"] as? String, "new-refresh")
        XCTAssertEqual(
            store.oauth["expiresAt"] as? Double,
            (now.timeIntervalSince1970 + 28_800) * 1_000
        )
    }

    /// Claude Code stores fields AgentHub does not model. Rewriting the blob
    /// must not drop them, or the CLI loses state it depends on.
    func testUnknownFieldsSurviveTheWriteBack() async {
        let store = FakeStore(blob(
            expiresAt: now.addingTimeInterval(-60),
            extras: ["subscriptionType": "pro", "rateLimitTier": "default_claude_ai"]
        ))
        let refresher = ClaudeTokenRefresher(
            store: store,
            post: { _ in (tokenResponse(), 200) },
            now: { now }
        )

        _ = await refresher.token()

        XCTAssertEqual(store.oauth["subscriptionType"] as? String, "pro")
        XCTAssertEqual(store.oauth["rateLimitTier"] as? String, "default_claude_ai")
    }

    /// The endpoint only returns a refresh token when it rotates one; a reply
    /// without one must leave the stored token alone rather than erase it.
    func testAbsentRotatedTokenKeepsTheStoredRefreshToken() async {
        let store = FakeStore(blob(expiresAt: now.addingTimeInterval(-60)))
        let refresher = ClaudeTokenRefresher(
            store: store,
            post: { _ in (tokenResponse(refresh: nil), 200) },
            now: { now }
        )

        _ = await refresher.token()

        XCTAssertEqual(store.oauth["refreshToken"] as? String, "old-refresh")
    }

    /// Claude Code may refresh while our request is in flight. Overwriting its
    /// newer credential with ours would strand the CLI.
    func testConcurrentRefreshByClaudeCodeIsNotClobbered() async {
        let store = FakeStore(blob(expiresAt: now.addingTimeInterval(-60)))
        let refresher = ClaudeTokenRefresher(
            store: store,
            post: { _ in
                // Stand in for Claude Code writing first.
                _ = store.save(blob(
                    accessToken: "cli-access",
                    refreshToken: "cli-refresh",
                    expiresAt: now.addingTimeInterval(28_800)
                ))
                return (tokenResponse(), 200)
            },
            now: { now }
        )

        let token = await refresher.token()

        XCTAssertEqual(token, "cli-access", "the newer credential wins")
        XCTAssertEqual(store.oauth["refreshToken"] as? String, "cli-refresh")
    }

    func testFailedRefreshLeavesTheStoredCredentialUntouched() async {
        let store = FakeStore(blob(expiresAt: now.addingTimeInterval(-60)))
        let refresher = ClaudeTokenRefresher(
            store: store,
            post: { _ in (Data("{\"error\":\"invalid_grant\"}".utf8), 400) },
            now: { now }
        )

        let token = await refresher.token()

        XCTAssertNil(token)
        XCTAssertEqual(store.writes, 0)
        XCTAssertEqual(store.oauth["accessToken"] as? String, "old-access")
    }

    func testRefreshRequestCarriesTheGrantClaudeCodeUses() async {
        let store = FakeStore(blob(expiresAt: now.addingTimeInterval(-60)))
        let captured = Captured()
        let refresher = ClaudeTokenRefresher(
            store: store,
            post: { body in
                captured.value = try? JSONSerialization.jsonObject(with: body) as? [String: String]
                return (tokenResponse(), 200)
            },
            now: { now }
        )

        _ = await refresher.token()

        XCTAssertEqual(captured.value?["grant_type"], "refresh_token")
        XCTAssertEqual(captured.value?["refresh_token"], "old-refresh")
        XCTAssertEqual(captured.value?["client_id"], ClaudeTokenRefresher.clientID)
    }

    /// A token about to lapse is renewed early, so it cannot expire between the
    /// check and the request that uses it.
    func testTokenInsideTheRenewMarginIsRefreshedEarly() async {
        let store = FakeStore(blob(
            expiresAt: now.addingTimeInterval(ClaudeTokenRefresher.renewMargin - 1)
        ))
        let refresher = ClaudeTokenRefresher(
            store: store,
            post: { _ in (tokenResponse(), 200) },
            now: { now }
        )

        let token = await refresher.token()
        XCTAssertEqual(token, "new-access")
    }

    func testForcedRefreshRenewsAnUnexpiredToken() async {
        let store = FakeStore(blob(expiresAt: now.addingTimeInterval(3_600)))
        let refresher = ClaudeTokenRefresher(
            store: store,
            post: { _ in (tokenResponse(), 200) },
            now: { now }
        )

        let token = await refresher.token(force: true)
        XCTAssertEqual(token, "new-access")
    }

    func testMissingCredentialYieldsNoToken() async {
        let refresher = ClaudeTokenRefresher(
            store: FakeStore(nil),
            post: { _ in XCTFail("nothing to refresh from"); return nil },
            now: { now }
        )

        let token = await refresher.token()
        let state = await refresher.diagnosis()
        XCTAssertNil(token)
        XCTAssertEqual(state, .noCredential)
    }

    func testDiagnosisNamesAnExpiredSignInWithNothingToRenewFrom() async {
        let store = FakeStore(blob(
            refreshToken: nil,
            expiresAt: now.addingTimeInterval(-60)
        ))
        let refresher = ClaudeTokenRefresher(store: store, post: { _ in nil }, now: { now })

        let state = await refresher.diagnosis()
        XCTAssertEqual(state, .expiredWithoutRefresh)
        XCTAssertNotNil(ClaudeCredentialState.expiredWithoutRefresh.panelMessage)
    }

    /// A working credential has nothing to explain, so the panel shows numbers
    /// rather than a notice.
    func testValidCredentialHasNoPanelMessage() async {
        let store = FakeStore(blob(expiresAt: now.addingTimeInterval(3_600)))
        let refresher = ClaudeTokenRefresher(store: store, post: { _ in nil }, now: { now })

        let state = await refresher.diagnosis()
        XCTAssertEqual(state, .valid)
        XCTAssertNil(ClaudeCredentialState.valid.panelMessage)
    }

    /// A failed Keychain write must not be reported as success: the caller still
    /// gets a usable token for this request, but nothing is silently lost.
    func testTokenIsStillReturnedWhenTheKeychainWriteFails() async {
        let store = FakeStore(blob(expiresAt: now.addingTimeInterval(-60)))
        store.saveSucceeds = false
        let refresher = ClaudeTokenRefresher(
            store: store,
            post: { _ in (tokenResponse(), 200) },
            now: { now }
        )

        let token = await refresher.token()
        XCTAssertEqual(token, "new-access")
    }
}

private final class Captured: @unchecked Sendable {
    var value: [String: String]?
}
