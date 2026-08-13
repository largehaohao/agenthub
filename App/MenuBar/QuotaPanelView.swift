import SwiftUI
import AgentHubQuota

/// The panel shown from the menu bar.
///
/// The percentages are the point, so they carry the visual weight and
/// everything else is support.
struct QuotaPanelView: View {
    @ObservedObject var model: QuotaPanelModel
    var onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            if model.rows.isEmpty {
                Text("No usage reported yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.rows) { row in
                    QuotaProviderSection(row: row)
                }
            }
        }
        .padding(22)
        .frame(width: 470)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Usage").font(.headline)
            Spacer()
            Button {
                Task { await model.load(force: true) }
            } label: {
                if model.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(model.isRefreshing)
            .help("Refresh usage from every provider")

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
    }
}

private struct QuotaProviderSection: View {
    let row: QuotaProviderRow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(row.displayName)
                .font(.caption.bold())
                .foregroundStyle(row.provider.accentColor)
            HStack(alignment: .top, spacing: 24) {
                ForEach(row.windows) { window in
                    QuotaFigure(window: window, tint: row.provider.accentColor)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct QuotaFigure: View {
    let window: QuotaPresentation
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(window.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if window.hasElapsed {
                    Text("ENDED").font(.caption2.bold()).foregroundStyle(.secondary)
                } else if window.isStale {
                    Text("STALE").font(.caption2.bold()).foregroundStyle(.orange)
                }
            }
            // Monospaced digits keep the number from shifting width as it changes.
            Text(window.displayPercent)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(window.hasElapsed ? Color.secondary : .primary)
            ProgressView(value: window.usedPercent, total: 100)
                .tint(window.hasElapsed ? .gray : tint)
                .frame(width: 118)
            // An elapsed window's reset time is in the past, so a countdown
            // would read as one that already fired.
            Text(window.hasElapsed
                 ? "window ended"
                 : "resets \(window.resetsAt, style: .relative)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

extension Provider {
    /// Distinct hue per provider so sections separate at a glance.
    var accentColor: Color {
        switch self {
        case .claude: .orange
        case .codex: .green
        case .cursor: .blue
        case .openCode: .purple
        }
    }
}
