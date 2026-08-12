import Foundation
import AgentHubCore

/// Display-ready form of one quota window. Keeping this separate from the view
/// lets the labelling and staleness rules be tested without SwiftUI.
struct QuotaPresentation: Identifiable, Equatable {
    let id: String
    /// Duration-derived window name only ("5h", "7d"). The provider is shown
    /// once per row, so repeating it on every window is noise.
    let title: String
    let accountPlan: String
    let usedPercent: Double
    let resetsAt: Date
    let source: String
    let isStale: Bool
    /// The window's reset time has passed, so this percentage describes a window
    /// that no longer exists. Claude stops reporting a window once it resets, so
    /// the last reading is retained but must not read as current.
    let hasElapsed: Bool

    init(window: QuotaWindow, now: Date) {
        // Providers name the same window differently ("Session", "Weekly",
        // "primary"). The duration is the one description that means the same
        // thing across providers, so it is the canonical name.
        id = window.id
        title = window.canonicalLabel
        accountPlan = [window.accountID, window.plan]
            .compactMap { $0 }
            .joined(separator: " · ")
        usedPercent = window.usedPercent
        resetsAt = window.resetsAt
        source = window.source
        isStale = window.isStale(now: now)
        hasElapsed = window.resetsAt <= now
    }

    /// Stale or elapsed numbers stay visible but must never drive a
    /// recommendation. This mirrors `QuotaWindow.availablePace`, which already
    /// returns nil in both cases.
    var informsRecommendations: Bool { !isStale && !hasElapsed }

    static func durationLabel(_ duration: TimeInterval) -> String {
        QuotaWindow.durationLabel(duration)
    }
}

/// One provider's windows, rendered as a single row.
struct QuotaProviderRow: Identifiable, Equatable {
    let id: String
    let provider: Provider
    let windows: [QuotaPresentation]

    var displayName: String { provider.displayName }

    /// Groups windows by provider and orders each row shortest-window-first, so
    /// the fastest-moving number is read first.
    static func rows(from quotas: [QuotaWindow], now: Date) -> [QuotaProviderRow] {
        Dictionary(grouping: quotas, by: \.provider)
            .map { provider, windows in
                QuotaProviderRow(
                    id: provider.rawValue,
                    provider: provider,
                    windows: windows
                        .sorted { $0.windowDuration < $1.windowDuration }
                        .map { QuotaPresentation(window: $0, now: now) }
                )
            }
            .sorted { $0.provider.rawValue < $1.provider.rawValue }
    }
}
