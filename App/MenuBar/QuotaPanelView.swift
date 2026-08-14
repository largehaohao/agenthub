import SwiftUI
import AgentHubQuota

/// The panel shown from the menu bar.
///
/// The percentages are the point, so they carry the visual weight and
/// everything else is support. The usage sections scale with `model.scale`;
/// the surrounding chrome stays put, so zooming enlarges what is being read
/// rather than the buttons doing the zooming.
struct QuotaPanelView: View {
    @ObservedObject var model: QuotaPanelModel
    var onOpenSettings: () -> Void
    var onClose: () -> Void
    var onQuit: () -> Void

    /// Unscaled metrics, in points at 100%.
    private enum Base {
        static let width = 460.0
        static let percent = 40.0
        static let sectionSpacing = 22.0
        static let padding = 22.0
        static let bar = 130.0
    }

    private var scale: Double { model.scale }

    var body: some View {
        VStack(alignment: .leading, spacing: Base.sectionSpacing * scale) {
            header

            if model.rows.isEmpty && model.notices.isEmpty {
                // Hiding every provider is a choice, not a failure, so it must
                // not read like one.
                Text(model.showsNoProviders
                     ? "No providers selected — choose some in Settings"
                     : "No usage reported yet")
                    .font(.system(size: 13 * scale))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.rows) { row in
                    QuotaProviderSection(row: row, scale: scale, bar: Base.bar, percent: Base.percent)
                }
                ForEach(orderedNotices, id: \.provider) { notice in
                    ProviderNotice(provider: notice.provider, message: notice.message, scale: scale)
                }
            }

            footer
        }
        .padding(Base.padding)
        // A minimum rather than a fixed width: OpenCode reports three windows,
        // which together are wider than the panel's resting size. Pinning the
        // width centred that row and clipped a digit off each edge.
        .frame(minWidth: Base.width * scale, alignment: .leading)
        .fixedSize()
    }

    /// Notices sort with the rows so a provider keeps one place in the list
    /// whether or not it is reporting.
    private var orderedNotices: [(provider: Provider, message: String)] {
        model.notices
            .map { (provider: $0.key, message: $0.value) }
            .sorted { $0.provider.rawValue < $1.provider.rawValue }
    }

    /// The header deliberately does not scale.
    ///
    /// Its controls sit at a fixed size and a fixed offset from the panel's
    /// left edge, so zooming never walks a button out from under the pointer
    /// that is clicking it. Only the usage itself grows.
    private var header: some View {
        HStack(spacing: 10) {
            Text("Usage").font(.system(size: 13, weight: .semibold))
            // Kept on the left, beside a label whose width barely changes:
            // zooming moves everything to its right, and a button that slides
            // out from under the pointer cannot be clicked twice.
            zoomControls
            Spacer(minLength: 0)

            PanelButton(symbol: "gearshape", help: "Settings", action: onOpenSettings)

            Button {
                Task { await model.load(force: true) }
            } label: {
                if model.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12))
                }
            }
            .buttonStyle(.borderless)
            .disabled(model.isRefreshing)
            .help("Refresh usage from every provider")

            PanelButton(symbol: "xmark", help: "Close this panel", action: onClose)
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 6) {
            PanelButton(symbol: "minus", help: "Smaller") { model.shrink() }
                .disabled(!model.canShrink)
            Text("\(Int((scale * 100).rounded()))%")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                // A fixed width keeps "100%" and "85%" from nudging the plus
                // button sideways as the reading changes.
                .frame(width: 34)
            PanelButton(symbol: "plus", help: "Larger") { model.enlarge() }
                .disabled(!model.canEnlarge)
        }
    }

    private var footer: some View {
        HStack {
            Spacer(minLength: 0)
            // Quitting stops usage updates entirely, so it is spelled out rather
            // than left as an icon next to Close.
            Button("Quit AgentHub", action: onQuit)
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

/// A fixed-size icon button in the panel's chrome.
private struct PanelButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

private struct QuotaProviderSection: View {
    let row: QuotaProviderRow
    let scale: Double
    let bar: Double
    let percent: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            Text(row.displayName)
                .font(.system(size: 11 * scale, weight: .bold))
                .foregroundStyle(row.provider.accentColor)
            HStack(alignment: .top, spacing: 24 * scale) {
                ForEach(row.windows) { window in
                    QuotaFigure(
                        window: window,
                        tint: row.provider.accentColor,
                        scale: scale,
                        bar: bar,
                        percent: percent
                    )
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// Stands in for a provider that reported nothing, naming the reason.
private struct ProviderNotice: View {
    let provider: Provider
    let message: String
    let scale: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            Text(provider.displayName)
                .font(.system(size: 11 * scale, weight: .bold))
                .foregroundStyle(provider.accentColor.opacity(0.6))
            Text(message)
                .font(.system(size: 11 * scale))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct QuotaFigure: View {
    let window: QuotaPresentation
    let tint: Color
    let scale: Double
    let bar: Double
    let percent: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5 * scale) {
            HStack(spacing: 5 * scale) {
                Text(window.title)
                    .font(.system(size: 11 * scale))
                    .foregroundStyle(.secondary)
                if window.hasElapsed {
                    Text("ENDED")
                        .font(.system(size: 9 * scale, weight: .bold))
                        .foregroundStyle(.secondary)
                } else if window.isStale {
                    Text("STALE")
                        .font(.system(size: 9 * scale, weight: .bold))
                        .foregroundStyle(.orange)
                }
            }
            // Monospaced digits keep the number from shifting width as it changes.
            Text(window.displayPercent)
                .font(.system(size: percent * scale, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(window.hasElapsed ? Color.secondary : .primary)
            ProgressView(value: window.usedPercent, total: 100)
                .tint(window.hasElapsed ? .gray : tint)
                .frame(width: bar * scale)
            // An elapsed window's reset time is in the past, so a countdown
            // would read as one that already fired.
            Text(window.hasElapsed
                 ? "window ended"
                 : "resets \(window.resetsAt, style: .relative)")
                .font(.system(size: 9 * scale))
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
