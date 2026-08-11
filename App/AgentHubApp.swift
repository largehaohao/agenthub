import SwiftUI

@main
struct AgentHubApp: App {
    private let client: any DaemonClientProtocol

    init() {
        client = AppEnvironment.makeDaemonClient()
    }

    var body: some Scene {
        WindowGroup {
            DashboardView(client: client)
                .frame(minWidth: 1_080, minHeight: 680)
        }
        .windowStyle(.titleBar)
    }
}
