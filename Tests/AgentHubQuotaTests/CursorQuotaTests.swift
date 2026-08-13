import Foundation
import XCTest
@testable import AgentHubQuota

/// `cursorAuth/accessToken` holds a bare JWT, but `cursor.com` expects the
/// session cookie to be `<sub>::<jwt>`. Sending the bare token returned
/// HTTP 401 `not_authenticated` against the live endpoint.
final class CursorSessionCookieTests: XCTestCase {
    /// Payload `{"sub":"google-oauth2|user_123","aud":"https://cursor.com"}`.
    private let jwt = [
        "eyJhbGciOiJIUzI1NiJ9",
        "eyJzdWIiOiJnb29nbGUtb2F1dGgyfHVzZXJfMTIzIiwiYXVkIjoiaHR0cHM6Ly9jdXJzb3IuY29tIn0",
        "signature",
    ].joined(separator: ".")

    func testCookiePrefixesSubjectFromTokenClaims() throws {
        let cookie = try XCTUnwrap(CursorQuotaClient.sessionCookieValue(for: jwt))

        XCTAssertEqual(cookie, "google-oauth2|user_123::\(jwt)")
    }

    /// A token that already carries the prefix must not be double-prefixed.
    func testAlreadyPrefixedTokenIsLeftAlone() throws {
        let composite = "google-oauth2|user_123::\(jwt)"

        XCTAssertEqual(CursorQuotaClient.sessionCookieValue(for: composite), composite)
    }

    /// An opaque (non-JWT) token is sent as-is rather than being mangled.
    func testNonJWTTokenIsUsedVerbatim() throws {
        XCTAssertEqual(CursorQuotaClient.sessionCookieValue(for: "opaque"), "opaque")
    }

    /// A JWT whose payload carries no subject cannot be prefixed.
    func testTokenWithoutSubjectFallsBackToRawToken() throws {
        let noSub = ["eyJhbGciOiJIUzI1NiJ9", "eyJhdWQiOiJ4In0", "sig"].joined(separator: ".")

        XCTAssertEqual(CursorQuotaClient.sessionCookieValue(for: noSub), noSub)
    }
}
