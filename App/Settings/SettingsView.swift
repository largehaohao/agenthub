import SwiftUI

struct SettingsView: View {
    @ObservedObject var cursor: CursorAuthorizationModel
    private let binding = HotKeyBinding.load()

    var body: some View {
        Form {
            Section("Shortcut") {
                LabeledContent("Show usage") {
                    Text(binding.displayName).monospaced()
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
