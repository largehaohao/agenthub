import SwiftUI
import AgentHubCore

struct DashboardView: View {
    @StateObject private var model: DashboardViewModel
    @State private var showingLaunch = false

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
                            && $0.ownership == .managed
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
                    Label("New Codex Task", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingLaunch) {
            LaunchCodexSheet { cwd, prompt in
                await model.launchCodex(cwd: cwd, prompt: prompt)
            }
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

private struct LaunchCodexSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var cwd = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var prompt = ""
    let onLaunch: (String, String) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Codex Task").font(.title2.bold())
            TextField("Working directory", text: $cwd)
            TextEditor(text: $prompt)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Launch") {
                    let cwd = cwd
                    let prompt = prompt
                    dismiss()
                    Task { await onLaunch(cwd, prompt) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(cwd.isEmpty || prompt.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}
