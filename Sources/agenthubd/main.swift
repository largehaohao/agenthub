import Darwin
import Dispatch
import Foundation
import AgentHubClaude
import AgentHubCodex
import AgentHubCore
import AgentHubDaemon
import AgentHubIPC
import AgentHubOpenCode
import AgentHubPersistence
import AgentHubSecurity

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

/// Builds the managed-terminal runtime only when Claude, tmux, and osascript
/// are all present. Without them Claude sessions are still discovered through
/// hooks; only managed launch is unavailable.
private func resolvedClaudeTerminal() -> TmuxClaudeTerminalRuntime? {
    let candidates = [
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/claude"),
        URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
        URL(fileURLWithPath: "/usr/local/bin/claude"),
    ]
    let tmuxCandidates = [
        URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        URL(fileURLWithPath: "/usr/local/bin/tmux"),
        URL(fileURLWithPath: "/usr/bin/tmux"),
    ]

    guard let claude = candidates.first(where: {
        FileManager.default.isExecutableFile(atPath: $0.path)
    }), let tmux = tmuxCandidates.first(where: {
        FileManager.default.isExecutableFile(atPath: $0.path)
    }) else { return nil }

    return TmuxClaudeTerminalRuntime(
        claudeExecutable: claude,
        tmuxExecutable: tmux,
        run: runClaudeCommand
    )
}

/// Points the installer at the user's Claude settings and the packaged hook
/// helper. Returns nil when the helper is absent so setup reports honestly
/// rather than writing a hook command that cannot run.
private func resolvedClaudeHookInstaller() -> ClaudeHookInstaller? {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let helper = home.appendingPathComponent(
        "Library/Application Support/AgentHub/bin/agenthub-claude-hook"
    )
    guard FileManager.default.isExecutableFile(atPath: helper.path) else { return nil }

    return ClaudeHookInstaller(
        settingsURL: home.appendingPathComponent(".claude/settings.json"),
        executableURL: helper
    )
}

/// Executes a command directly with an argument array; no shell is involved.
@Sendable
private func runClaudeCommand(_ command: ClaudeCommand) async throws -> ClaudeCommandResult {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: command.executable)
    process.arguments = command.arguments
    process.standardOutput = output
    process.standardError = Pipe()

    if let standardInput = command.standardInput {
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(standardInput.utf8))
        try? input.fileHandleForWriting.close()
    } else {
        try process.run()
    }

    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return ClaudeCommandResult(
        standardOutput: String(decoding: data, as: UTF8.self),
        exitStatus: process.terminationStatus
    )
}

/// Runs a quota-source command, capturing stdout and stderr separately and
/// terminating the child if it overruns. No shell is involved.
@Sendable
private func runQuotaCommand(_ command: ClaudeCommand) async throws -> QuotaCommandResult {
    let process = Process()
    let output = Pipe()
    let errorOutput = Pipe()
    process.executableURL = URL(fileURLWithPath: command.executable)
    process.arguments = command.arguments
    process.standardOutput = output
    process.standardError = errorOutput
    try process.run()

    // The child gets a hard ceiling above CodexBar's own --timeout so a hung
    // process can never stall the refresh loop.
    let watchdog = Task {
        try? await Task.sleep(for: .seconds(15))
        if process.isRunning { process.terminate() }
    }
    defer { watchdog.cancel() }

    let outputData = output.fileHandleForReading.readDataToEndOfFile()
    let errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    if watchdog.isCancelled == false, process.terminationReason == .uncaughtSignal {
        throw ClaudeQuotaError.timeout
    }

    return QuotaCommandResult(
        standardOutput: String(decoding: outputData, as: UTF8.self),
        standardError: String(decoding: errorData, as: UTF8.self),
        exitStatus: process.terminationStatus
    )
}

/// Confirms a freshly installed CodexBar can actually produce Claude JSON.
@Sendable
private func validateCodexBar() async throws {
    let collector = CodexBarClaudeQuotaCollector(
        location: CodexBarLocation.discover(),
        run: runQuotaCommand
    )
    _ = try await collector.collect()
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
    writeLog("runtime prepared")

    let store = try AgentHubStore(databaseURL: paths.database)
    let transport = CodexProcess()
    let rpc = CodexRPCClient(transport: transport)
    try await rpc.start(clientName: "AgentHub", clientVersion: AgentHubCoreVersion.current)
    writeLog("provider connected")

    let codexAdapter = CodexAdapter(accountID: "default", rpc: rpc)
    let credentialStore = KeychainCredentialStore()
    let openCodeRegistry = OpenCodeEndpointRegistry()
    let managedOpenCode = ManagedOpenCodeServer()
    let openCodeDiscovery = MacOpenCodeDiscovery()
    let openCodeAdapter = OpenCodeHybridAdapter(
        registry: openCodeRegistry,
        managedServer: managedOpenCode,
        discovery: openCodeDiscovery,
        credentialStore: credentialStore
    )
    let claudeAdapter = ClaudeAdapter(
        accountID: "default",
        transcripts: ClaudeTranscriptReader(
            claudeRoot: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude", isDirectory: true)
        ),
        terminal: resolvedClaudeTerminal(),
        hookInstaller: resolvedClaudeHookInstaller(),
        quotaCollector: CodexBarClaudeQuotaCollector(
            location: CodexBarLocation.discover(),
            run: runQuotaCommand
        ),
        quotaInstaller: CodexBarInstaller(
            brewPath: CodexBarInstaller.resolveBrew(),
            run: runQuotaCommand,
            validate: validateCodexBar
        )
    )
    let adapters: [Provider: any AgentAdapter] = [
        .codex: codexAdapter,
        .openCode: openCodeAdapter,
        .claude: claudeAdapter,
    ]
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
        writeLog("provider reconciled")
        // Quota collection runs independently of session support, so a missing
        // or unauthenticated CodexBar never delays or blocks daemon startup.
        await claudeAdapter.startQuotaRefresh()
        let server = try await UnixDaemonServer.bind(path: paths.socket) { command in
            await api.handle(command)
        }
        writeLog("ipc ready")
        // `changes()` is one shared stream, so a second consumer would steal
        // events from the relay. Both effects are driven from this one loop.
        let reconciler = DeliveryReconciler(handoffs: handoffService)
        let relay = Task {
            let changes = await coordinator.changes()
            for await sequence in changes {
                await server.broadcast(.stateChanged(sequence: sequence))
                await reconciler.reconcile(await coordinator.snapshot())
            }
        }

        var signals = terminationSignals().makeAsyncIterator()
        _ = await signals.next()
        relay.cancel()
        await server.stop()
        await coordinator.stop()
        await claudeAdapter.stopQuotaRefresh()
        await openCodeAdapter.shutdown()
        await rpc.stop()
    } catch {
        await coordinator.stop()
        await claudeAdapter.stopQuotaRefresh()
        await openCodeAdapter.shutdown()
        await rpc.stop()
        throw error
    }
}

private func writeLog(_ message: String) {
    FileHandle.standardOutput.write(Data("agenthubd: \(message)\n".utf8))
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
