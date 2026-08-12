import SwiftUI
import AgentHubCore

struct DashboardView: View {
    @StateObject private var model: DashboardViewModel
    @State private var showingLaunch = false
    @State private var showingOpenCodeSettings = false
    @State private var showingClaudeSettings = false

    init(client: any DaemonClientProtocol) {
        _model = StateObject(wrappedValue: DashboardViewModel(client: client))
    }

    var body: some View {
        VStack(spacing: 0) {
            AdapterHealthView(health: model.state.adapterHealth)
            QuotaStripView(quotas: Array(model.state.quotas.values))
            Divider()
            NavigationSplitView {
                SessionTreeView(
                    sessions: Array(model.state.sessions.values),
                    nodes: Array(model.state.nodes.values),
                    selection: $model.selectedSessionID
                )
                .navigationSplitViewColumnWidth(min: 230, ideal: 280, max: 360)
            } content: {
                SessionDetailView(
                    session: model.selectedSession,
                    handoffTargets: model.state.sessions.values.filter {
                        $0.id != model.selectedSessionID
                            && $0.capabilities[.sendInput] == .l1
                    },
                    onSend: { text, id in await model.send(text, to: id) },
                    onJump: { id in await model.jump(to: id) },
                    onHandoff: { source, target, limit, note in
                        await model.handoff(
                            source: source,
                            target: target,
                            turnLimit: limit,
                            note: note
                        )
                    }
                )
            } detail: {
                RequestInboxView(
                    requests: Array(model.state.requests.values),
                    canResolve: model.canResolve,
                    onResolve: { id, decision in
                        await model.resolve(id, decision: decision)
                    },
                    onAuthenticate: { endpointID, password in
                        await model.authenticateOpenCode(
                            endpointID: endpointID,
                            password: password
                        )
                    }
                )
                .navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 420)
            }
        }
        .overlay(alignment: .bottom) {
            if let message = model.message {
                Text(message)
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding()
            }
        }
        .toolbar {
            ToolbarItemGroup {
                connectionLabel
                Button {
                    showingLaunch = true
                } label: {
                    Label("New Task", systemImage: "plus")
                }
                Button {
                    showingOpenCodeSettings = true
                } label: {
                    Label("OpenCode Settings", systemImage: "network")
                }
                Button {
                    showingClaudeSettings = true
                } label: {
                    Label("Claude Settings", systemImage: "sparkles")
                }
            }
        }
        .sheet(isPresented: $showingLaunch) {
            LaunchTaskSheet { provider, cwd, prompt, agent, selectedModel in
                await model.launch(
                    provider: provider,
                    cwd: cwd,
                    prompt: prompt,
                    agent: agent,
                    model: selectedModel
                )
            }
        }
        .sheet(isPresented: $showingOpenCodeSettings) {
            OpenCodeSettingsView(
                endpoints: model.state.endpoints.values.filter { $0.provider == .openCode },
                onAttach: { url, password in
                    await model.attachOpenCode(url: url, password: password)
                },
                onDetach: { endpoint in
                    await model.detachOpenCode(endpoint: endpoint)
                }
            )
        }
        .sheet(isPresented: $showingClaudeSettings) {
            ClaudeSettingsView(
                components: model.state.components.values
                    .filter { $0.provider == .claude }
                    .sorted { $0.component < $1.component },
                onConfigure: { action in
                    await model.configure(provider: .claude, action: action)
                }
            )
        }
        .task { await model.connect() }
    }

    @ViewBuilder
    private var connectionLabel: some View {
        switch model.connection {
        case .connecting:
            ProgressView().controlSize(.small).help("Connecting to AgentHub daemon")
        case .connected:
            Label("Connected", systemImage: "bolt.horizontal.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.iconOnly)
                .help("AgentHub daemon connected")
        case .disconnected(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .labelStyle(.iconOnly)
                .help(reason)
        }
    }
}

private struct LaunchTaskSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var provider: Provider = .codex
    @State private var cwd = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var prompt = ""
    @State private var agent = ""
    @State private var providerID = ""
    @State private var modelID = ""
    @State private var variant = ""
    let onLaunch: (
        Provider,
        String,
        String,
        String?,
        LaunchModelSelection?
    ) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Task").font(.title2.bold())
            Picker("Provider", selection: $provider) {
                Text("Codex").tag(Provider.codex)
                Text("Claude").tag(Provider.claude)
                Text("OpenCode").tag(Provider.openCode)
            }
            .pickerStyle(.segmented)
            TextField("Working directory", text: $cwd)
            if provider == .openCode {
                Group {
                    TextField("Agent (optional)", text: $agent)
                    TextField("Model provider ID (optional)", text: $providerID)
                    TextField("Model ID (optional)", text: $modelID)
                    TextField("Model variant (optional)", text: $variant)
                }
            }
            TextEditor(text: $prompt)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Launch") {
                    let cwd = cwd
                    let prompt = prompt
                    let provider = provider
                    let agent = optional(agent)
                    let selectedModel: LaunchModelSelection?
                    if let providerID = optional(providerID),
                       let modelID = optional(modelID) {
                        selectedModel = .init(
                            providerID: providerID,
                            modelID: modelID,
                            variant: optional(variant)
                        )
                    } else {
                        selectedModel = nil
                    }
                    dismiss()
                    Task {
                        await onLaunch(provider, cwd, prompt, agent, selectedModel)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(cwd.isEmpty || prompt.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private func optional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
