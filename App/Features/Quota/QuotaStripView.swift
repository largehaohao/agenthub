import SwiftUI
import AgentHubCore

struct QuotaStripView: View {
    let quotas: [QuotaWindow]

    var body: some View {
        if !quotas.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 18) {
                    ForEach(presentations) { quota in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(quota.title).font(.caption.bold())
                                if quota.isStale {
                                    Text("STALE").font(.caption2.bold()).foregroundStyle(.orange)
                                }
                            }
                            ProgressView(value: quota.usedPercent, total: 100)
                                .frame(width: 150)
                                .opacity(quota.isStale ? 0.5 : 1)
                            Text("\(Int(quota.usedPercent))% used · resets \(quota.resetsAt, style: .relative)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(quota.accountPlan.isEmpty ? quota.source
                                 : "\(quota.accountPlan) · \(quota.source)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }
        }
    }

    private var presentations: [QuotaPresentation] {
        let now = Date()
        return quotas
            .sorted { $0.windowDuration < $1.windowDuration }
            .map { QuotaPresentation(window: $0, now: now) }
    }
}
