import Foundation
import AgentHubCore

/// Display-ready form of one quota window. Keeping this separate from the view
/// lets the labelling and staleness rules be tested without SwiftUI.
struct QuotaPresentation: Identifiable, Equatable {
    let id: String
    let title: String
    let accountPlan: String
    let usedPercent: Double
    let resetsAt: Date
    let source: String
    let isStale: Bool

    init(window: QuotaWindow, now: Date) {
        // A source-provided label is the most accurate description; duration is
        // only a fallback for providers that do not name their windows.
        let name = window.label ?? Self.durationLabel(window.windowDuration)
        id = window.id
        title = "\(window.provider.rawValue.capitalized) · \(name)"
        accountPlan = [window.accountID, window.plan]
            .compactMap { $0 }
            .joined(separator: " · ")
        usedPercent = window.usedPercent
        resetsAt = window.resetsAt
        source = window.source
        isStale = window.isStale(now: now)
    }

    /// Stale numbers stay visible but must never drive a recommendation.
    var informsRecommendations: Bool { !isStale }

    static func durationLabel(_ duration: TimeInterval) -> String {
        let hours = Int(duration / 3_600)
        return hours >= 24 ? "\(hours / 24)d" : "\(hours)h"
    }
}
