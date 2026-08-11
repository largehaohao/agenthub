// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentHub",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentHubCore", targets: ["AgentHubCore"]),
        .library(name: "AgentHubPersistence", targets: ["AgentHubPersistence"]),
        .library(name: "AgentHubIPC", targets: ["AgentHubIPC"]),
        .library(name: "AgentHubCodex", targets: ["AgentHubCodex"]),
        .library(name: "AgentHubDaemon", targets: ["AgentHubDaemon"]),
        .library(name: "AgentHubTestSupport", targets: ["AgentHubTestSupport"]),
        .executable(name: "agenthubd", targets: ["agenthubd"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.10.0"),
        .package(url: "https://github.com/apple/swift-nio.git", "2.87.0"..<"2.98.0"),
    ],
    targets: [
        .target(name: "AgentHubCore"),
        .target(
            name: "AgentHubPersistence",
            dependencies: [
                "AgentHubCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "AgentHubIPC",
            dependencies: [
                "AgentHubCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .target(name: "AgentHubCodex", dependencies: ["AgentHubCore"]),
        .target(
            name: "AgentHubDaemon",
            dependencies: [
                "AgentHubCore",
                "AgentHubPersistence",
                "AgentHubIPC",
                "AgentHubCodex",
            ]
        ),
        .target(name: "AgentHubTestSupport", dependencies: ["AgentHubCore"]),
        .executableTarget(name: "agenthubd", dependencies: ["AgentHubDaemon"]),
        .testTarget(
            name: "AgentHubCoreTests",
            dependencies: ["AgentHubCore", "AgentHubTestSupport"]
        ),
        .testTarget(
            name: "AgentHubPersistenceTests",
            dependencies: ["AgentHubPersistence", "AgentHubTestSupport"]
        ),
        .testTarget(
            name: "AgentHubIPCTests",
            dependencies: ["AgentHubIPC", "AgentHubTestSupport"]
        ),
        .testTarget(
            name: "AgentHubCodexTests",
            dependencies: ["AgentHubCodex", "AgentHubTestSupport"]
        ),
        .testTarget(
            name: "AgentHubDaemonTests",
            dependencies: ["AgentHubDaemon", "AgentHubTestSupport"]
        ),
    ]
)
