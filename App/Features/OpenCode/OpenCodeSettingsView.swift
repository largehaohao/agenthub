import SwiftUI
import AgentHubCore

struct OpenCodeSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let endpoints: [ProviderEndpoint]
    let onAttach: (String, String) async -> Void
    let onDetach: (ProviderEndpoint) async -> Void
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            List {
                Section("Endpoints") {
                    ForEach(endpoints.sorted { $0.id < $1.id }) { endpoint in
                        endpointRow(endpoint)
                    }
                    if endpoints.isEmpty {
                        Text("No OpenCode endpoints discovered.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Quota") {
                    Text("OpenCode Go quota is not available yet.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("OpenCode Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Endpoint") { showingAdd = true }
                }
            }
        }
        .frame(minWidth: 620, minHeight: 440)
        .sheet(isPresented: $showingAdd) {
            AddOpenCodeEndpointSheet(onAttach: onAttach)
        }
    }

    private func endpointRow(_ endpoint: ProviderEndpoint) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: endpoint.connected ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(endpoint.connected ? .green : .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(endpoint.origin.label).font(.headline)
                Text(endpoint.baseURL)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    if let version = endpoint.version { Text("v\(version)") }
                    Text(endpoint.connected ? "Connected" : "Disconnected")
                    if let message = endpoint.message { Text(message) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if endpoint.origin == .manual {
                Button("Detach", role: .destructive) {
                    Task { await onDetach(endpoint) }
                }
            } else if endpoint.credentialReference != nil {
                Button("Forget password", role: .destructive) {
                    Task { await onDetach(endpoint) }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct AddOpenCodeEndpointSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAttach: (String, String) async -> Void
    @State private var url = "http://127.0.0.1:4096"
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add OpenCode Endpoint").font(.title2.bold())
            TextField("Loopback URL", text: $url)
            SecureField("Password (optional)", text: $password)
            if !url.isEmpty && !isValidLoopbackURL {
                Text("Enter an HTTP loopback URL with an explicit port.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Attach") {
                    let submittedURL = url
                    let submittedPassword = password
                    password = ""
                    dismiss()
                    Task { await onAttach(submittedURL, submittedPassword) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValidLoopbackURL)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onDisappear { password = "" }
    }

    private var isValidLoopbackURL: Bool {
        guard let components = URLComponents(string: url),
              components.scheme == "http",
              let host = components.host?.lowercased(),
              components.port != nil else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}

private extension ProviderEndpointOrigin {
    var label: String {
        switch self {
        case .managed: "AgentHub Managed"
        case .desktop: "OpenCode Desktop"
        case .tui: "OpenCode TUI"
        case .manual: "Manual"
        }
    }
}
