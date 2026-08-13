import Foundation
import AgentHubQuota

@MainActor
final class QuotaPanelModel: ObservableObject {
    @Published private(set) var rows: [QuotaProviderRow] = []
    @Published private(set) var isRefreshing = false

    private let service: QuotaService
    private let now: @Sendable () -> Date

    init(service: QuotaService, now: @escaping @Sendable () -> Date = { Date() }) {
        self.service = service
        self.now = now
    }

    func load(force: Bool) async {
        isRefreshing = true
        defer { isRefreshing = false }
        let windows = await service.windows(force: force)
        rows = QuotaProviderRow.rows(from: windows, now: now())
    }
}
