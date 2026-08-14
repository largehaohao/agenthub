import Foundation
import AgentHubQuota

@MainActor
final class QuotaPanelModel: ObservableObject {
    @Published private(set) var rows: [QuotaProviderRow] = []
    /// Why a provider reported nothing, shown in place of its numbers.
    @Published private(set) var notices: [Provider: String] = [:]
    @Published private(set) var isRefreshing = false
    /// Multiplies every type size in the panel, so the numbers can be made
    /// readable from across the room.
    @Published var scale: Double {
        didSet {
            guard scale != oldValue else { return }
            defaults.set(scale, forKey: Self.scaleKey)
        }
    }

    static let scaleRange: ClosedRange<Double> = 0.8...2.5
    static let scaleStep = 0.15
    private static let scaleKey = "panelScale"

    private let service: QuotaService
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date

    init(
        service: QuotaService,
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        self.defaults = defaults
        self.now = now
        let stored = defaults.double(forKey: Self.scaleKey)
        // A never-set default reads as 0, which would collapse the panel.
        self.scale = Self.scaleRange.contains(stored) ? stored : 1.0
    }

    func load(force: Bool) async {
        isRefreshing = true
        defer { isRefreshing = false }
        let windows = await service.windows(force: force)
        rows = QuotaProviderRow.rows(from: windows, now: now())
        notices = await service.currentNotices()
    }

    var canEnlarge: Bool { scale < Self.scaleRange.upperBound - 0.001 }
    var canShrink: Bool { scale > Self.scaleRange.lowerBound + 0.001 }

    func enlarge() { setScale(scale + Self.scaleStep) }
    func shrink() { setScale(scale - Self.scaleStep) }

    private func setScale(_ value: Double) {
        scale = min(max(value, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
    }
}
