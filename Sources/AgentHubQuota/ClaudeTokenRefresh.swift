import Foundation
import Security

/// Where Claude Code keeps its OAuth blob.
///
/// Abstracted so the refresher can be exercised without touching the login
/// Keychain.
public protocol ClaudeCredentialStore: Sendable {
    func load() -> Data?
    func save(_ data: Data) -> Bool
}

/// The login Keychain item Claude Code writes.
public struct ClaudeKeychainStore: ClaudeCredentialStore {
    /// The service name Claude Code files its credential under.
    public static let defaultService = "Claude Code-credentials"

    private let service: String

    public init(service: String = ClaudeKeychainStore.defaultService) {
        self.service = service
    }

    private var match: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
    }

    public func load() -> Data? {
        var query = match
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        return item as? Data
    }

    /// Updates the existing item in place. Never creates one: if Claude Code has
    /// not logged in there is nothing to refresh, and inventing an item would
    /// leave a credential behind that AgentHub owns.
    public func save(_ data: Data) -> Bool {
        let attributes = [kSecValueData as String: data] as CFDictionary
        return SecItemUpdate(match as CFDictionary, attributes) == errSecSuccess
    }
}

/// The file Claude Code keeps its credential in.
///
/// This is the store Claude Code actually maintains: it rewrites the file every
/// time it refreshes, whereas the login Keychain item is written once at sign-in
/// and can be left behind holding a dead token.
public struct ClaudeCredentialFileStore: ClaudeCredentialStore {
    public static let defaultURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.credentials.json")

    private let url: URL

    public init(url: URL = ClaudeCredentialFileStore.defaultURL) {
        self.url = url
    }

    public func load() -> Data? {
        try? Data(contentsOf: url)
    }

    /// Never creates the file: if Claude Code has not signed in there is nothing
    /// to refresh, and inventing one would leave a credential AgentHub owns.
    public func save(_ data: Data) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            try data.write(to: url, options: [.atomic])
            // An atomic write replaces the file, so its owner-only mode has to
            // be reapplied or the credential would be left world-readable.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            return true
        } catch {
            return false
        }
    }
}

/// Reads whichever store holds the credential Claude Code is keeping current.
///
/// Both stores exist in the wild, and a Mac can hold both at once — one of them
/// stale. Choosing by expiry rather than by preference means a leftover never
/// shadows the live one.
public struct ClaudeCredentialStores: ClaudeCredentialStore {
    private let stores: [ClaudeCredentialStore]

    public init(_ stores: [ClaudeCredentialStore]) {
        self.stores = stores
    }

    public static var standard: ClaudeCredentialStores {
        ClaudeCredentialStores([ClaudeCredentialFileStore(), ClaudeKeychainStore()])
    }

    public func load() -> Data? {
        freshest()?.data
    }

    public func save(_ data: Data) -> Bool {
        freshest()?.store.save(data) ?? false
    }

    private func freshest() -> (store: ClaudeCredentialStore, data: Data)? {
        stores
            .compactMap { store -> (store: ClaudeCredentialStore, data: Data, expiry: Date)? in
                guard let data = store.load(),
                      let blob = ClaudeCredentialBlob(data: data) else { return nil }
                // A credential with no expiry cannot be compared, so it sorts
                // last and is only used when nothing else is readable.
                return (store, data, blob.expiresAt ?? .distantPast)
            }
            .max { $0.expiry < $1.expiry }
            .map { ($0.store, $0.data) }
    }
}

/// The token endpoint's reply, sent back over `ClaudeTokenPost`.
public typealias ClaudeTokenPost = @Sendable (Data) async -> (body: Data, status: Int)?

/// Renews Claude Code's OAuth access token.
///
/// Claude Code's access token lasts eight hours and is only renewed when it
/// actually makes a request, so a Mac that has not run it since this morning
/// holds an expired token and reports no usage at all. AgentHub performs the
/// same refresh Claude Code performs and writes the result back to the store it
/// came from, so a rotated refresh token does not log the CLI out.
///
/// This is the only credential AgentHub writes, and it writes it only where
/// Claude Code already keeps it. AgentHub keeps no copy of its own: `token()`
/// returns it for the caller's single request.
public actor ClaudeTokenRefresher {
    public static let tokenEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// Claude Code's public OAuth client identifier. Not a secret; it is the
    /// same value baked into the CLI.
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// Renew this far ahead of expiry so a token cannot lapse mid-request.
    public static let renewMargin: TimeInterval = 300

    private let store: ClaudeCredentialStore
    private let post: ClaudeTokenPost
    private let now: @Sendable () -> Date
    /// The endpoint refused the grant itself. Distinguished from a network
    /// failure, which is worth retrying and says nothing about the credential.
    private var refreshRejected = false

    public init(
        store: ClaudeCredentialStore = ClaudeCredentialStores.standard,
        post: @escaping ClaudeTokenPost = ClaudeTokenRefresher.livePost,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.post = post
        self.now = now
    }

    /// A usable access token, refreshing first when the stored one has expired.
    ///
    /// - Parameter force: refresh even if the stored token still looks valid,
    ///   for the retry after the API rejects it anyway.
    /// - Returns: nil when Claude Code is signed out, when the item cannot be
    ///   read, or when the refresh fails.
    public func token(force: Bool = false) async -> String? {
        guard let blob = load() else { return nil }

        if !force, let token = blob.accessToken, !blob.expiresSoon(now: now()) {
            return token
        }
        guard let refreshToken = blob.refreshToken else {
            // Signed in but with nothing to renew from: an expired token here is
            // terminal until the user runs `claude auth login`.
            return force ? nil : blob.accessToken
        }
        return await refresh(using: refreshToken)
    }

    /// Why usage is unavailable, for the panel to show instead of an empty row.
    public func diagnosis() -> ClaudeCredentialState {
        guard let blob = load() else { return .noCredential }
        guard blob.accessToken != nil else { return .noCredential }
        // A current token supersedes any earlier rejection: signing in again
        // writes a fresh credential here.
        if !blob.expiresSoon(now: now()) { return .valid }
        if refreshRejected { return .refreshRejected }
        return blob.refreshToken == nil ? .expiredWithoutRefresh : .refreshable
    }

    private func load() -> ClaudeCredentialBlob? {
        store.load().flatMap(ClaudeCredentialBlob.init(data:))
    }

    private func refresh(using refreshToken: String) async -> String? {
        let request: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: request),
              let reply = await post(body) else {
            return nil
        }
        guard reply.status == 200, let renewed = ClaudeRenewedToken(data: reply.body) else {
            // 4xx is the grant being refused — retrying cannot fix it, and the
            // panel should say so rather than keep showing nothing. A 5xx or a
            // transport failure says nothing about the credential.
            if (400..<500).contains(reply.status) { refreshRejected = true }
            return nil
        }
        refreshRejected = false

        // Re-read before writing: Claude Code may have refreshed in the moment
        // this request was in flight, and overwriting its newer token with ours
        // would strand it. Whoever wrote last wins, and both stay usable.
        guard var current = load() else { return renewed.accessToken }
        guard current.refreshToken == refreshToken else {
            return current.accessToken ?? renewed.accessToken
        }

        current.apply(renewed, now: now())
        _ = current.encoded().map(store.save)
        return renewed.accessToken
    }

    /// Posts to the real token endpoint.
    public static let livePost: ClaudeTokenPost = { body in
        var request = URLRequest(url: ClaudeTokenRefresher.tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            return nil
        }
        return (data, http.statusCode)
    }
}

/// Why Claude usage is or is not available, in the user's terms.
public enum ClaudeCredentialState: Equatable, Sendable {
    /// Claude Code is not signed in on this Mac, or its store is unreadable.
    case noCredential
    /// The stored token is current.
    case valid
    /// Expired, with a refresh token that has not been refused.
    case refreshable
    /// Expired with nothing to renew from.
    case expiredWithoutRefresh
    /// The refresh token was rejected outright, so no amount of retrying will
    /// help. Signing in again is the only fix.
    case refreshRejected

    /// Why there are no numbers. Never nil: this is only ever consulted when
    /// Claude reported nothing, and "nothing, unexplained" is the state that
    /// made the same gap look like a bug twice.
    public var panelMessage: String {
        switch self {
        case .noCredential:
            "Claude Code is not signed in on this Mac"
        case .expiredWithoutRefresh, .refreshRejected:
            "Claude sign-in expired — run `claude` to sign in again"
        case .valid, .refreshable:
            "Claude usage is temporarily unavailable"
        }
    }
}

/// Claude Code's credential JSON, edited in place.
///
/// The whole object is preserved on write: it carries fields AgentHub does not
/// understand, and dropping them would degrade Claude Code's own state.
struct ClaudeCredentialBlob {
    private var root: [String: Any]
    private var oauth: [String: Any]

    init?(data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any] else {
            return nil
        }
        self.root = root
        self.oauth = oauth
    }

    var accessToken: String? {
        (oauth["accessToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    var refreshToken: String? {
        (oauth["refreshToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    var expiresAt: Date? {
        (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1_000) }
    }

    /// A credential with no expiry is treated as current: Claude Code always
    /// writes one, so its absence means a shape we should not second-guess.
    func expiresSoon(now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= ClaudeTokenRefresher.renewMargin
    }

    mutating func apply(_ renewed: ClaudeRenewedToken, now: Date) {
        oauth["accessToken"] = renewed.accessToken
        oauth["expiresAt"] = (now.timeIntervalSince1970 + renewed.expiresIn) * 1_000
        // The endpoint only returns a refresh token when it rotates one.
        if let rotated = renewed.refreshToken {
            oauth["refreshToken"] = rotated
        }
        if let lifetime = renewed.refreshTokenExpiresIn {
            oauth["refreshTokenExpiresAt"] = (now.timeIntervalSince1970 + lifetime) * 1_000
        }
        root["claudeAiOauth"] = oauth
    }

    func encoded() -> Data? {
        try? JSONSerialization.data(withJSONObject: root)
    }
}

/// The token endpoint's success payload.
struct ClaudeRenewedToken {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: TimeInterval
    let refreshTokenExpiresIn: TimeInterval?

    init?(data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String,
              !token.isEmpty,
              let expiresIn = ClaudeUsageWindows.double(json["expires_in"]) else {
            return nil
        }
        self.accessToken = token
        self.refreshToken = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.expiresIn = expiresIn
        self.refreshTokenExpiresIn = ClaudeUsageWindows.double(json["refresh_token_expires_in"])
    }
}
