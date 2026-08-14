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

    let service: QuotaService
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

    /// Every provider is hidden, so an empty panel is the user's own doing.
    @Published private(set) var showsNoProviders = false

    func load(force: Bool) async {
        isRefreshing = true
        defer { isRefreshing = false }
        let windows = await service.windows(force: force)
        rows = QuotaProviderRow.rows(from: windows, now: now())
        notices = await service.currentNotices()
        showsNoProviders = await service.shownProviders().isEmpty
    }

    /// The largest scale that still fits the screen, once one has been found.
    ///
    /// Discovered rather than calculated: how tall the panel gets depends on how
    /// many windows the providers happen to report, which changes.
    private var ceiling = QuotaPanelModel.scaleRange.upperBound

    var canEnlarge: Bool { scale < min(Self.scaleRange.upperBound, ceiling) - 0.001 }
    var canShrink: Bool { scale > Self.scaleRange.lowerBound + 0.001 }

    /// Enforces the ceiling here rather than leaving it to the button's disabled
    /// state, so the shortcut and any other caller obey it too.
    func enlarge() { setScale(min(scale + Self.scaleStep, ceiling)) }

    func shrink() {
        // Shrinking makes room again, so a ceiling found earlier no longer
        // applies — a provider may also have stopped reporting since.
        ceiling = Self.scaleRange.upperBound
        setScale(scale - Self.scaleStep)
    }

    /// Gives back a zoom step that turned out not to fit on screen, and refuses
    /// to offer it again until the panel shrinks.
    func refuseEnlargement() {
        setScale(scale - Self.scaleStep)
        // The ceiling is the step that fits, not the one that did not: setting
        // it to the rejected value would offer the same step straight back and
        // leave the button toggling between two sizes.
        ceiling = scale
    }

    private func setScale(_ value: Double) {
        scale = min(max(value, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
    }
}
