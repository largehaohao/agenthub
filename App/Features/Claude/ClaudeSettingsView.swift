import SwiftUI
import AgentHubCore

/// Shows Claude runtime component health and the explicit setup actions.
///
/// Hook installation is always a deliberate user action: nothing here runs on
/// its own, and uninstall is offered alongside install so the user can always
/// take AgentHub back out of their Claude settings.
struct ClaudeSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let components: [ProviderComponentStatus]
    let onConfigure: (ProviderConfigurationAction) async -> Void

    /// Components the first slice reports on, in display order.
    private static let expected = [
        ("hooks", "Claude hooks", "Lets AgentHub observe sessions you start yourself."),
        ("binary", "Claude Code", "The claude executable used for managed sessions."),
        ("tmux", "tmux", "Backs managed Claude sessions so they survive window closes."),
        ("iterm", "iTerm", "Shows managed Claude sessions as a normal terminal."),
        ("accessibility", "Accessibility", "Optional. Enables exact Claude Desktop navigation."),
        ("statusline", "Usage reporter", "Optional. Reports Claude usage limits."),
    ]

    private var quotaReporterInstalled: Bool {
        components.first { $0.component == "statusline" }?.available == true
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Components") {
                    ForEach(Self.expected, id: \.0) { component in
                        row(id: component.0, title: component.1, detail: component.2)
                    }
                }
                Section("Setup") {
                    Button("Install AgentHub Hooks") {
                        Task { await onConfigure(.installHooks) }
                    }
                    Button("Remove AgentHub Hooks") {
                        Task { await onConfigure(.uninstallHooks) }
                    }
                    Text("Installing adds AgentHub's hook to your user Claude settings and "
                         + "leaves every other setting untouched.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Usage") {
                    if quotaReporterInstalled {
                        Button("Remove Usage Reporter") {
                            Task { await onConfigure(.uninstallQuotaReporter) }
                        }
                    } else {
                        Button("Install Usage Reporter") {
                            Task { await onConfigure(.installQuotaReporter) }
                        }
                    }
                    Text("Usage comes from Claude Code itself, through its status line. "
                         + "Installing keeps any status line you already have and adds "
                         + "AgentHub alongside it; removing restores it exactly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Claude Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh") {
                        Task { await onConfigure(.refreshComponents) }
                    }
                }
            }
        }
        .frame(minWidth: 620, minHeight: 440)
    }

    private func row(id: String, title: String, detail: String) -> some View {
        let status = components.first { $0.component == id }

        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: status?.available == true
                  ? "checkmark.circle.fill"
                  : "exclamationmark.circle")
                .foregroundStyle(status?.available == true ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(status?.message ?? detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let path = status?.path {
                    Text(path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if let version = status?.version {
                Text(version).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
