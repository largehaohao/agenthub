import SwiftUI
import AgentHubCore

struct AdapterHealthView: View {
    let health: [Provider: AdapterHealth]

    var body: some View {
        if !health.isEmpty {
            HStack(spacing: 14) {
                ForEach(health.keys.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { provider in
                    if let status = health[provider] {
                        Label(
                            status.message ?? "\(provider.rawValue.capitalized) \(status.connected ? "connected" : "unavailable")",
                            systemImage: status.connected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(status.connected ? .green : .orange)
                    }
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 7)
            .background(.bar)
        }
    }
}
