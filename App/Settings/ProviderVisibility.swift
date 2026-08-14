import Foundation
import AgentHubQuota

/// Which providers the user wants in the panel.
///
/// Stored as the shown set rather than the hidden one, so a provider added in a
/// later version has to be opted into rather than appearing unannounced in a
/// panel someone has already tuned.
@MainActor
final class ProviderVisibility: ObservableObject {
    private static let key = "shownProviders"

    @Published private(set) var shown: Set<Provider>

    /// Applied to the service, which skips fetching anything hidden.
    var onChange: ((Set<Provider>) -> Void)?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Nothing stored means a first run, not "everything hidden".
        if let stored = defaults.array(forKey: Self.key) as? [String] {
            shown = Set(stored.compactMap(Provider.init(rawValue:)))
        } else {
            shown = Set(Provider.allCases)
        }
    }

    func isShown(_ provider: Provider) -> Bool {
        shown.contains(provider)
    }

    func setShown(_ provider: Provider, _ isShown: Bool) {
        var updated = shown
        if isShown {
            updated.insert(provider)
        } else {
            updated.remove(provider)
        }
        guard updated != shown else { return }
        shown = updated
        // Written as an array: UserDefaults has no set type, and the raw values
        // survive a provider being renamed in a way an ordinal would not.
        defaults.set(updated.map(\.rawValue).sorted(), forKey: Self.key)
        onChange?(updated)
    }

    /// Providers in a stable order, for a settings list that does not reshuffle.
    var allProviders: [Provider] {
        Provider.allCases.sorted { $0.displayName < $1.displayName }
    }
}
