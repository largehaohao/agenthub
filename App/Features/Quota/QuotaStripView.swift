import SwiftUI
import AgentHubCore

struct QuotaStripView: View {
    let quotas: [QuotaWindow]
    var isRefreshing: Bool = false
    var onRefresh: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        // The strip is rebuilt on every daemon state change. Implicit
        // animations restart on each rebuild, and cells could be left stranded
        // mid-transition -- faded and blurred rather than drawn.
        .transaction { $0.animation = nil }
        // The window behind this strip is translucent, so any area the strip
        // does not paint shows a blurred desktop rather than an empty cell.
        .background(Color(nsColor: .windowBackgroundColor))
        // NavigationSplitView below this strip is greedy, and without this the
        // strip is compressed below its ideal height: rows then overlap, text is
        // clipped, and a whole provider row can render blank.
        .fixedSize(horizontal: false, vertical: true)
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

            // Deliberately not a ScrollView. A row whose cells overflow becomes
            // scrollable, and macOS then applies a scroll-edge effect that
            // blurs the whole row -- which is why only Cursor, the widest row,
            // rendered as an unreadable smear. A provider reports at most a
            // handful of windows, so a plain row of fixed-width cells fits.
            HStack(alignment: .top, spacing: 16) {
                ForEach(row.windows) { window in
                    QuotaWindowView(window: window, tint: row.provider.accentColor)
                }
                Spacer(minLength: 0)
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
                if window.hasElapsed {
                    Text("ENDED").font(.caption2.bold()).foregroundStyle(.secondary)
                } else if window.isStale {
                    Text("STALE").font(.caption2.bold()).foregroundStyle(.orange)
                }
            }
            ProgressView(value: window.usedPercent, total: 100)
                .tint(window.hasElapsed ? .gray : tint)
                .frame(width: 150)
                .opacity(window.informsRecommendations ? 1 : 0.5)
            // An elapsed window's reset time is in the past, so "resets in ..."
            // would read as a countdown that already fired.
            Text(window.hasElapsed
                 ? "\(window.displayPercent) used · window ended"
                 : "\(window.displayPercent) used · resets \(window.resetsAt, style: .relative)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        // A uniform cell width keeps every provider's windows on the same
        // vertical gridlines and stops a long caption from shifting the row.
        .frame(width: 175, alignment: .leading)
    }
}

extension View {
    /// Turns off the soft scroll-edge effect introduced on macOS 26.
    ///
    /// The effect is applied across the split view's width and bleeds over the
    /// quota strip above it, progressively blurring everything past the sidebar
    /// edge. It is a no-op before macOS 26, which has no such effect.
    @ViewBuilder
    func quotaStripLegibleScrollEdges() -> some View {
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectStyle(.hard, for: .all)
        } else {
            self
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
