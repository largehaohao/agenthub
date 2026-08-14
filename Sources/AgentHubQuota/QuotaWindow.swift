import Foundation

public enum Provider: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
    case cursor
    case openCode
}

public extension Provider {
    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .openCode: "OpenCode"
        case .claude: "Claude"
        case .cursor: "Cursor"
        }
    }
}

public enum ModelValidationError: Error, Equatable, Sendable {
    case quotaPercentOutOfRange
    case nonPositiveWindowDuration
}

public struct QuotaWindow: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let provider: Provider
    public let accountID: String
    /// Source-provided window key. A provider may report several windows that
    /// share a duration (an overall five-hour window and a per-model one), so
    /// this participates in `id` to keep them distinct.
    public let windowID: String?
    public let label: String?
    public let plan: String?
    public let usedPercent: Double
    public let windowDuration: TimeInterval
    public let resetsAt: Date
    public let fetchedAt: Date
    public let source: String

    public init(
        provider: Provider,
        accountID: String,
        windowID: String? = nil,
        label: String? = nil,
        plan: String? = nil,
        usedPercent: Double,
        windowDuration: TimeInterval,
        resetsAt: Date,
        fetchedAt: Date,
        source: String
    ) throws {
        guard (0...100).contains(usedPercent) else {
            throw ModelValidationError.quotaPercentOutOfRange
        }
        guard windowDuration > 0 else {
            throw ModelValidationError.nonPositiveWindowDuration
        }

        // An unnamed window keeps the plain identity, so a provider that starts
        // naming its windows produces new rows rather than colliding with old.
        let base = "\(provider.rawValue):\(accountID):\(Int(windowDuration))"
        self.id = windowID.map { "\(base):\($0)" } ?? base
        self.provider = provider
        self.accountID = accountID
        self.windowID = windowID
        self.label = label
        self.plan = plan
        self.usedPercent = usedPercent
        self.windowDuration = windowDuration
        self.resetsAt = resetsAt
        self.fetchedAt = fetchedAt
        self.source = source
    }

    public func isStale(now: Date, sourceTTL: TimeInterval? = nil) -> Bool {
        now.timeIntervalSince(fetchedAt) > (sourceTTL ?? 15 * 60)
    }

    /// Canonical window name. Providers name the same window differently
    /// ("Session", "Weekly", "primary"), so the duration is the one description
    /// that means the same thing everywhere: 5h, 7d.
    public static func durationLabel(_ duration: TimeInterval) -> String {
        let hours = Int((duration / 3_600).rounded())
        guard hours >= 24 else { return "\(hours)h" }
        let days = Int((duration / 86_400).rounded())
        return "\(days)d"
    }

    /// Duration-derived name, ignoring the provider's own wording.
    public var canonicalLabel: String { Self.durationLabel(windowDuration) }
}
