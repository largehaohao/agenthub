import SwiftUI
import AgentHubCore

struct QuotaStripView: View {
    let quotas: [QuotaWindow]

    var body: some View {
        if !quotas.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 18) {
                    ForEach(quotas.sorted { $0.windowDuration < $1.windowDuration }) { quota in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("\(quota.provider.rawValue.capitalized) · \(durationLabel(quota.windowDuration))")
                                    .font(.caption.bold())
                                if quota.isStale(now: Date()) {
                                    Text("STALE").font(.caption2.bold()).foregroundStyle(.orange)
                                }
                            }
                            ProgressView(value: quota.usedPercent, total: 100)
                                .frame(width: 150)
                            Text("\(Int(quota.usedPercent))% used · resets \(quota.resetsAt, style: .relative)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(quota.source)
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

    private func durationLabel(_ duration: TimeInterval) -> String {
        let hours = Int(duration / 3_600)
        return hours >= 24 ? "\(hours / 24)d" : "\(hours)h"
    }
}
