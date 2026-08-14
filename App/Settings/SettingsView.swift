import SwiftUI
import AgentHubQuota

struct SettingsView: View {
    @ObservedObject var cursor: CursorAuthorizationModel
    @ObservedObject var hotKey: HotKeyModel
    @ObservedObject var providers: ProviderVisibility

    var body: some View {
        Form {
            Section("Providers") {
                ForEach(providers.allProviders, id: \.self) { provider in
                    Toggle(provider.displayName, isOn: Binding(
                        get: { providers.isShown(provider) },
                        set: { providers.setShown(provider, $0) }
                    ))
                }
                Text("Hidden providers are not shown and not contacted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Shortcut") {
                LabeledContent("Show usage") {
                    HotKeyRecorder(model: hotKey)
                }
                Text("Press this anywhere to open the usage panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Cursor") {
                if cursor.isAuthorized {
                    LabeledContent("Usage reading") { Text("Active") }
                    Button("Revoke") { Task { await cursor.revoke() } }
                } else {
                    Text("""
                    Cursor usage requires reading the session token Cursor stores \
                    on this Mac. It is used for one request and never saved.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Button("Authorize usage reading") { Task { await cursor.authorize() } }
                }
                if let message = cursor.message {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 430)
    }
}
