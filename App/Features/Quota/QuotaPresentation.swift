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

    init(window: QuotaWindow, now: Date, disambiguateWithLabel: Bool = false) {
        // Providers name the same window differently ("Session", "Weekly",
        // "primary"). The duration is the one description that means the same
        // thing across providers, so it is the canonical name. Cursor is the
        // exception: its Auto/API/Total windows share one billing cycle, so the
        // duration alone would render three identical titles.
        id = window.id
        if disambiguateWithLabel, let label = window.label {
            title = "\(window.canonicalLabel) · \(label)"
        } else {
            title = window.canonicalLabel
        }
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

    /// Whole-number percentage. Cursor reports long fractions such as
    /// 39.35333333333333, which must not reach the strip verbatim.
    var displayPercent: String { "\(Int(usedPercent.rounded()))%" }

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
                // Only fall back to the provider's own label when the duration
                // does not identify a window on its own.
                let durations = windows.map(\.windowDuration)
                let ambiguous = Set(durations).count != durations.count
                return QuotaProviderRow(
                    id: provider.rawValue,
                    provider: provider,
                    windows: windows
                        // Windows arrive from a dictionary, so their incoming
                        // order is arbitrary and changes between refreshes.
                        // Ties break on window id, which is stable and gives
                        // Cursor its api / auto / total reading order.
                        .sorted {
                            $0.windowDuration == $1.windowDuration
                                ? ($0.windowID ?? "") < ($1.windowID ?? "")
                                : $0.windowDuration < $1.windowDuration
                        }
                        .map {
                            QuotaPresentation(
                                window: $0,
                                now: now,
                                disambiguateWithLabel: ambiguous
                            )
                        }
                )
            }
            .sorted { $0.provider.rawValue < $1.provider.rawValue }
    }
}
