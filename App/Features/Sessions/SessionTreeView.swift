import SwiftUI
import AgentHubCore

struct SessionTreeView: View {
    let sessions: [AgentSession]
    let nodes: [AgentNode]
    @Binding var selection: UUID?

    private var rows: [SessionTreeRow] {
        SessionTreeBuilder.build(sessions: sessions, nodes: nodes)
    }

    var body: some View {
        List {
            Section("Running") {
                ForEach(rows.filter(\.isActive)) { row in
                    TreeRowView(row: row, selection: $selection)
                }
            }
            Section("Recent") {
                ForEach(rows.filter { !$0.isActive }) { row in
                    TreeRowView(row: row, selection: $selection)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Agents")
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(
                    "No agents yet",
                    systemImage: "cpu",
                    description: Text("Launch a Codex task to begin.")
                )
            }
        }
    }
}

private struct TreeRowView: View {
    let row: SessionTreeRow
    @Binding var selection: UUID?
    @State private var isExpanded = true

    var body: some View {
        if row.children.isEmpty {
            label
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(row.children) { child in
                    TreeRowView(row: child, selection: $selection)
                }
            } label: {
                label
            }
        }
    }

    private var label: some View {
        Button {
            selection = row.sessionID
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(row.status.color)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).lineLimit(1)
                    Text(row.status.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .background(
            selection == row.sessionID ? Color.accentColor.opacity(0.12) : .clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
    }
}

private extension SessionTreeRow {
    var sessionID: UUID {
        switch value {
        case .session(let session): session.id
        case .node(let node): node.sessionID
        }
    }

    var title: String {
        switch value {
        case .session(let session): session.title
        case .node(let node): "\(node.kind) · \(node.nativeID)"
        }
    }

    var status: SessionStatus {
        switch value {
        case .session(let session): session.status
        case .node(let node): node.status
        }
    }

    var isActive: Bool {
        switch status {
        case .starting, .working, .waitingPermission, .waitingInput, .idle: true
        case .completed, .error, .disconnected: false
        }
    }
}

extension SessionStatus {
    var label: String {
        switch self {
        case .starting: "Starting"
        case .working: "Working"
        case .waitingPermission: "Needs permission"
        case .waitingInput: "Needs input"
        case .idle: "Idle"
        case .completed: "Completed"
        case .error: "Error"
        case .disconnected: "Disconnected"
        }
    }

    var color: Color {
        switch self {
        case .starting: .blue
        case .working: .green
        case .waitingPermission, .waitingInput: .orange
        case .idle: .teal
        case .completed: .secondary
        case .error: .red
        case .disconnected: .gray
        }
    }
}
