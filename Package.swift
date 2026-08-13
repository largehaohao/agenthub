// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentHub",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentHubQuota", targets: ["AgentHubQuota"]),
    ],
    targets: [
        .target(
            name: "AgentHubQuota",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(name: "AgentHubQuotaTests", dependencies: ["AgentHubQuota"]),
    ]
)
