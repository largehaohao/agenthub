import Foundation
import AgentHubCore

public enum CursorQuotaClientError: Error, Equatable, Sendable {
    case invalidResponse
    case httpStatus(Int)
}

/// Fetches Cursor dashboard usage and maps it into shared `QuotaWindow` rows.
///
/// Pinned endpoint (live-probed): `GET https://cursor.com/api/usage-summary`
/// with cookie `WorkosCursorSessionToken=<access token from state.vscdb>`.
public struct CursorQuotaClient: Sendable {
    public static let usageSummaryURL = URL(string: "https://cursor.com/api/usage-summary")!

    private let accountID: String
    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(
        accountID: String,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.accountID = accountID
        self.session = session
        self.now = now
    }

    /// Builds the `WorkosCursorSessionToken` cookie value.
    ///
    /// Cursor stores a bare JWT in `cursorAuth/accessToken`, but `cursor.com`
    /// expects `<sub>::<jwt>`; sending the bare token returns HTTP 401
    /// `not_authenticated`. The subject is read from the token's own claims, so
    /// no additional credential is needed. A token that is already prefixed, is
    /// not a JWT, or carries no subject is used unchanged rather than mangled.
    static func sessionCookieValue(for token: String) -> String {
        guard !token.contains("::") else { return token }

        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return token }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)

        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = claims["sub"] as? String,
              !subject.isEmpty else {
            return token
        }
        return "\(subject)::\(token)"
    }

    public func fetchWindows(token: String) async throws -> [QuotaWindow] {
        var request = URLRequest(url: Self.usageSummaryURL)
        request.httpMethod = "GET"
        request.setValue(
            "WorkosCursorSessionToken=\(Self.sessionCookieValue(for: token))",
            forHTTPHeaderField: "Cookie"
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CursorQuotaClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CursorQuotaClientError.httpStatus(http.statusCode)
        }

        return try Self.decodeWindows(
            data,
            accountID: accountID,
            fetchedAt: now()
        )
    }

    static func decodeWindows(
        _ data: Data,
        accountID: String,
        fetchedAt: Date
    ) throws -> [QuotaWindow] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CursorQuotaClientError.invalidResponse
        }

        guard let resetsAt = timestamp(root["billingCycleEnd"]) else {
            return []
        }

        let startsAt = timestamp(root["billingCycleStart"]) ?? resetsAt
        let duration = max(resetsAt.timeIntervalSince(startsAt), 1)
        let plan = root["membershipType"] as? String

        guard let individual = root["individualUsage"] as? [String: Any],
              let planUsage = individual["plan"] as? [String: Any] else {
            return []
        }

        let known: [(key: String, label: String, field: String)] = [
            ("auto", "Auto", "autoPercentUsed"),
            ("api", "API", "apiPercentUsed"),
            ("total", "Total", "totalPercentUsed"),
        ]

        return known.compactMap { known -> QuotaWindow? in
            guard let usedPercent = double(planUsage[known.field]) else {
                return nil
            }
            return try? QuotaWindow(
                provider: .cursor,
                accountID: accountID,
                windowID: known.key,
                label: known.label,
                plan: plan,
                usedPercent: usedPercent,
                windowDuration: duration,
                resetsAt: resetsAt,
                fetchedAt: fetchedAt,
                source: "cursor-dashboard"
            )
        }
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }

    private static func timestamp(_ value: Any?) -> Date? {
        if let text = value as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: text)
        }
        if let seconds = double(value) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}
