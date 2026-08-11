import Darwin
import Dispatch
import Foundation
import AgentHubCodex
import AgentHubCore
import AgentHubDaemon
import AgentHubIPC
import AgentHubPersistence

private struct DaemonPaths {
    let directory: URL
    let database: URL
    let socket: String

    static func resolve(fileManager: FileManager = .default) throws -> DaemonPaths {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let directory = applicationSupport.appendingPathComponent("AgentHub", isDirectory: true)
        return DaemonPaths(
            directory: directory,
            database: directory.appendingPathComponent("agenthub.sqlite"),
            socket: directory.appendingPathComponent("agenthub.sock").path
        )
    }
}

private func prepareDirectory(_ url: URL, fileManager: FileManager = .default) throws {
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}

private func terminationSignals() -> AsyncStream<Int32> {
    AsyncStream { continuation in
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        interrupt.setEventHandler {
            continuation.yield(SIGINT)
            continuation.finish()
        }
        terminate.setEventHandler {
            continuation.yield(SIGTERM)
            continuation.finish()
        }
        continuation.onTermination = { _ in
            interrupt.cancel()
            terminate.cancel()
        }
        interrupt.activate()
        terminate.activate()
    }
}

private func runDaemon(paths: DaemonPaths) async throws {
    _ = umask(S_IRWXG | S_IRWXO)
    try prepareDirectory(paths.directory)

    let store = try AgentHubStore(databaseURL: paths.database)
    let transport = CodexProcess()
    let rpc = CodexRPCClient(transport: transport)
    try await rpc.start(clientName: "AgentHub", clientVersion: AgentHubCoreVersion.current)

    let adapter = CodexAdapter(accountID: "default", rpc: rpc)
    let adapters: [Provider: any AgentAdapter] = [.codex: adapter]
    let coordinator = Coordinator(store: store, adapters: adapters)
    let requestService = RequestService(store: store, adapters: adapters)
    let handoffService = HandoffService(store: store, adapters: adapters)
    let api = DaemonAPI(
        coordinator: coordinator,
        requests: requestService,
        handoffs: handoffService
    )

    do {
        try await coordinator.start()
        let server = try await UnixDaemonServer.bind(path: paths.socket) { command in
            await api.handle(command)
        }
        let relay = Task {
            let changes = await coordinator.changes()
            for await sequence in changes {
                await server.broadcast(.stateChanged(sequence: sequence))
            }
        }

        var signals = terminationSignals().makeAsyncIterator()
        _ = await signals.next()
        relay.cancel()
        await server.stop()
        await coordinator.stop()
        await rpc.stop()
    } catch {
        await coordinator.stop()
        await rpc.stop()
        throw error
    }
}

do {
    let paths = try DaemonPaths.resolve()
    if CommandLine.arguments.contains("--check-config") {
        print("database=\(paths.database.path)")
        print("socket=\(paths.socket)")
    } else {
        try await runDaemon(paths: paths)
    }
} catch {
    FileHandle.standardError.write(Data("agenthubd failed to start\n".utf8))
    exit(EXIT_FAILURE)
}
