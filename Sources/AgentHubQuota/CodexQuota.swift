import Foundation

/// Decodes the Codex app server's rate-limit snapshot.
///
/// Codex reports snake_case (`used_percent`, `window_minutes`, `resets_at`).
/// Both spellings are accepted, because reading only one of them once produced
/// no windows at all without any error to explain why.
public struct CodexQuotaDecoder: Sendable {
    public static let source = "codex-app-server"

    private let accountID: String

    public init(accountID: String) { self.accountID = accountID }

    /// A malformed payload yields no windows rather than throwing: usage is
    /// supplementary and must not fail a refresh.
    public func decode(_ data: Data, now: Date) throws -> [QuotaWindow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = root["rateLimits"] as? [String: Any] else { return [] }
        let plan = limits["plan_type"] as? String ?? limits["planType"] as? String
        return ["primary", "secondary"].compactMap { key in
            guard let entry = limits[key] as? [String: Any] else { return nil }
            return window(entry, windowID: key, plan: plan, now: now)
        }
    }

    private func window(
        _ entry: [String: Any],
        windowID: String,
        plan: String?,
        now: Date
    ) -> QuotaWindow? {
        // A window missing any of these carries no usable number, and 0% would
        // read as "plenty left" rather than "unknown".
        guard let used = number(entry["used_percent"] ?? entry["usedPercent"]),
              let minutes = number(entry["window_minutes"] ?? entry["windowDurationMins"]),
              let reset = number(entry["resets_at"] ?? entry["resetsAt"]) else { return nil }
        let duration = minutes * 60
        return try? QuotaWindow(
            provider: .codex,
            accountID: accountID,
            // Without a window id the two entries collapse onto one row when
            // they happen to share a duration.
            windowID: windowID,
            label: QuotaWindow.durationLabel(duration),
            plan: plan,
            usedPercent: used,
            windowDuration: duration,
            resetsAt: Date(timeIntervalSince1970: reset),
            fetchedAt: now,
            source: Self.source
        )
    }

    private func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }
}

/// Fetches Codex usage by running `codex app-server` for a single call.
///
/// ChatGPT Desktop keeps its own app server on a private stdio channel, so
/// AgentHub starts a short-lived one of its own. It is the only quota source
/// needing a subprocess; the alternative, reading `~/.codex/sessions/`, is only
/// as fresh as the last Codex run.
public struct CodexQuotaClient: Sendable {
    private let decoder: CodexQuotaDecoder
    private let now: @Sendable () -> Date

    public init(
        accountID: String = "default",
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.decoder = CodexQuotaDecoder(accountID: accountID)
        self.now = now
    }

    /// Returns no windows when Codex is absent or the call fails, so this one
    /// source degrades rather than the whole panel.
    public func fetch() async -> [QuotaWindow] {
        let transport = CodexProcess()
        let rpc = CodexRPCClient(transport: transport)
        defer { Task { await rpc.stop() } }

        guard (try? await rpc.start(clientName: "AgentHub", clientVersion: "1")) != nil,
              let result = try? await rpc.call(
                  method: "account/rateLimits/read",
                  params: nil,
                  timeout: .seconds(10)
              ),
              let data = try? JSONEncoder().encode(result) else {
            return []
        }
        return (try? decoder.decode(data, now: now())) ?? []
    }
}
