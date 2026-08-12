import Foundation

/// Persists only whether the user authorized Cursor usage reading.
///
/// Deliberately stores a boolean — never an access token.
public final class CursorQuotaAuthStore: @unchecked Sendable {
    public static let suiteName = "com.agenthub.cursor"
    private static let authorizedKey = "quotaAuthorized"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults? = nil) {
        if let defaults {
            self.defaults = defaults
        } else {
            self.defaults = UserDefaults(suiteName: Self.suiteName) ?? .standard
        }
    }

    public var isAuthorized: Bool {
        defaults.bool(forKey: Self.authorizedKey)
    }

    public func authorize() {
        defaults.set(true, forKey: Self.authorizedKey)
    }

    public func revoke() {
        defaults.set(false, forKey: Self.authorizedKey)
    }
}
