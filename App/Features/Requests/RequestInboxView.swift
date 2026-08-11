import SwiftUI
import AgentHubCore

struct RequestInboxView: View {
    let requests: [PendingRequest]
    let canResolve: (UUID) -> Bool
    let onResolve: (UUID, RequestDecision) async -> Void

    private var actionable: [PendingRequest] {
        requests
            .filter { $0.state == .pending || $0.state == .resolving }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        List(actionable) { request in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(request.title).font(.headline)
                    Spacer()
                    ReliabilityBadge(level: request.reliability)
                }
                Text(request.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Decline") {
                        Task { await onResolve(request.id, .decline) }
                    }
                    .disabled(!canResolve(request.id))
                    Spacer()
                    if request.state == .resolving {
                        ProgressView().controlSize(.small)
                    }
                    Button("Allow") {
                        Task { await onResolve(request.id, .accept) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canResolve(request.id))
                }
            }
            .padding(.vertical, 6)
        }
        .navigationTitle("Requests")
        .overlay {
            if actionable.isEmpty {
                ContentUnavailableView("No pending requests", systemImage: "checkmark.circle")
            }
        }
    }
}
