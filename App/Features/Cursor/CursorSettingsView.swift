import SwiftUI
import AgentHubCore

/// Shows Cursor component health and explicit setup actions.
///
/// Hook installation and usage authorization are deliberate user actions.
/// Nothing here runs on its own, and every action has a matching undo.
struct CursorSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let components: [ProviderComponentStatus]
    let onConfigure: (ProviderConfigurationAction) async -> Void

    private static let expected = [
        ("hooks", "Cursor hooks", "Lets AgentHub observe IDE Agent Chat sessions."),
        ("quota", "Usage access", "Optional. Reads Cursor usage after you authorize it."),
    ]

    private var hooksInstalled: Bool {
        components.first { $0.component == "hooks" }?.available == true
    }

    private var quotaAuthorized: Bool {
        components.first { $0.component == "quota" }?.available == true
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
                    Text("Installing merges AgentHub into ~/.cursor/hooks.json and "
                         + "leaves OpenIsland and other hooks untouched.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Usage") {
                    if quotaAuthorized {
                        Button("Revoke Usage Access") {
                            Task { await onConfigure(.revokeQuotaAccess) }
                        }
                    } else {
                        Button("Authorize Usage Reading") {
                            Task { await onConfigure(.authorizeQuotaAccess) }
                        }
                    }
                    Text("Authorization lets AgentHub read the local Cursor login "
                         + "session to query usage. The token is never stored in "
                         + "AgentHub's database.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Cursor Settings")
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
        .frame(minWidth: 620, minHeight: 400)
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
        }
        .padding(.vertical, 2)
    }
}
