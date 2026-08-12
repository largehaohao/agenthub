import SwiftUI
import AgentHubCore

struct QuotaStripView: View {
    let quotas: [QuotaWindow]
    var isRefreshing: Bool = false
    var onRefresh: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if rows.isEmpty {
                Text("No quota reported yet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                ForEach(rows) { row in
                    QuotaProviderRowView(row: row)
                }
            }
        }
        .padding(.vertical, 10)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Usage").font(.caption.bold()).foregroundStyle(.secondary)
            Spacer()
            if let onRefresh {
                Button(action: onRefresh) {
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshing)
                .help("Refresh usage from every provider")
                .accessibilityLabel("Refresh usage")
            }
        }
        .padding(.horizontal)
    }

    private var rows: [QuotaProviderRow] {
        QuotaProviderRow.rows(from: quotas, now: Date())
    }
}

/// One provider per row: a colored provider chip, then its windows.
private struct QuotaProviderRowView: View {
    let row: QuotaProviderRow

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(row.displayName)
                .font(.caption2.bold())
                .foregroundStyle(row.provider.accentColor)
                .frame(width: 62, alignment: .leading)
                .padding(.top, 1)

            ScrollView(.horizontal) {
                HStack(spacing: 16) {
                    ForEach(row.windows) { window in
                        QuotaWindowView(window: window, tint: row.provider.accentColor)
                    }
                }
            }
        }
        .padding(.horizontal)
    }
}

private struct QuotaWindowView: View {
    let window: QuotaPresentation
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(window.title).font(.caption.bold())
                if window.isStale {
                    Text("STALE").font(.caption2.bold()).foregroundStyle(.orange)
                }
            }
            ProgressView(value: window.usedPercent, total: 100)
                .tint(tint)
                .frame(width: 140)
                .opacity(window.isStale ? 0.5 : 1)
            Text("\(Int(window.usedPercent))% used · resets \(window.resetsAt, style: .relative)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

extension Provider {
    /// Distinct hue per provider so rows are separable at a glance.
    var accentColor: Color {
        switch self {
        case .claude: .orange
        case .codex: .green
        case .cursor: .blue
        case .openCode: .purple
        }
    }
}
