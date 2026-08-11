import SwiftUI
import AgentHubCore

struct SessionDetailView: View {
    let session: AgentSession?
    let handoffTargets: [AgentSession]
    let onSend: (String, UUID) async -> Void
    let onJump: (UUID) async -> Void
    let onHandoff: (UUID, UUID, Int, String?) async -> Void
    @State private var composer = ""
    @State private var showingHandoff = false

    var body: some View {
        Group {
            if let session {
                VStack(alignment: .leading, spacing: 0) {
                    header(session)
                    Divider()
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(session.preview) { turn in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(turn.role.capitalized)
                                        .font(.caption.bold())
                                        .foregroundStyle(.secondary)
                                    Text(turn.text).textSelection(.enabled)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .padding()
                    }
                    if canCompose(session) {
                        Divider()
                        HStack(alignment: .bottom, spacing: 10) {
                            TextField("Send input to this agent", text: $composer, axis: .vertical)
                                .lineLimit(1...5)
                            Button("Send") {
                                let text = composer
                                composer = ""
                                Task { await onSend(text, session.id) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .padding()
                    }
                }
                .navigationTitle(session.title)
                .sheet(isPresented: $showingHandoff) {
                    HandoffSheet(source: session, targets: handoffTargets, onSubmit: onHandoff)
                }
            } else {
                ContentUnavailableView("Select an agent", systemImage: "sidebar.left")
            }
        }
    }

    private func header(_ session: AgentSession) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Label(session.status.label, systemImage: "circle.fill")
                    .foregroundStyle(session.status.color)
                Text("\(session.providerRef.provider.displayName) · \(session.surface)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(session.cwd ?? "No working directory")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let branch = session.branch {
                    Text("Branch: \(branch)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Hand off") { showingHandoff = true }
                .disabled(handoffTargets.isEmpty)
            ReliabilityBadge(level: session.capabilities[.jump])
            Button("Open") { Task { await onJump(session.id) } }
                .disabled(session.capabilities[.jump] == nil)
        }
        .padding()
    }

    private func canCompose(_ session: AgentSession) -> Bool {
        session.capabilities[.sendInput] == .l1
    }
}

private struct HandoffSheet: View {
    @Environment(\.dismiss) private var dismiss
    let source: AgentSession
    let targets: [AgentSession]
    let onSubmit: (UUID, UUID, Int, String?) async -> Void
    @State private var targetID: UUID?
    @State private var turnLimit = 3
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Hand off context").font(.title2.bold())
            Text("From \(source.title)").foregroundStyle(.secondary)
            Picker("Target agent", selection: $targetID) {
                Text("Choose an agent").tag(UUID?.none)
                ForEach(targets.sorted { $0.lastActivityAt > $1.lastActivityAt }) { target in
                    Text(target.title).tag(Optional(target.id))
                }
            }
            Stepper("Recent turns: \(turnLimit)", value: $turnLimit, in: 1...20)
            TextField("Optional note", text: $note)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Send handoff") {
                    guard let targetID else { return }
                    let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
                    dismiss()
                    Task {
                        await onSubmit(source.id, targetID, turnLimit, note.isEmpty ? nil : note)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(targetID == nil)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

struct ReliabilityBadge: View {
    let level: ReliabilityLevel?

    var body: some View {
        if let level {
            Text("L\(level.rawValue)")
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.blue.opacity(0.15), in: Capsule())
                .foregroundStyle(.blue)
        }
    }
}
