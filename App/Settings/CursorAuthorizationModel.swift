import Foundation
import AgentHubQuota

/// Cursor usage needs an explicit opt-in, because reading it means reading the
/// session token Cursor stored on this Mac. That never happens unasked.
@MainActor
final class CursorAuthorizationModel: ObservableObject {
    @Published private(set) var isAuthorized = false
    @Published private(set) var message: String?

    private let collector: CursorQuotaCollector

    init(collector: CursorQuotaCollector = .live()) {
        self.collector = collector
        Task { await refreshState() }
    }

    func authorize() async {
        await collector.authorize()
        _ = try? await collector.refresh()
        await refreshState()
    }

    func revoke() async {
        await collector.revoke()
        await refreshState()
    }

    private func refreshState() async {
        isAuthorized = await collector.isAuthorized
        message = await collector.lastErrorMessage
    }
}
