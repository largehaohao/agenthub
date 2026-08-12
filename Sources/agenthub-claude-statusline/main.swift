import Darwin
import Foundation
import AgentHubClaude
import AgentHubCore
import AgentHubIPC

/// One-shot bridge invoked by Claude Code with the status-line payload on
/// stdin. It reports Claude's own `rate_limits` to the AgentHub daemon.
///
/// It writes nothing to stdout and always exits zero: the user's own status
/// line owns the display, and an unavailable daemon must never disturb it.
private let endToEndTimeout: Duration = .milliseconds(500)

private func socketPath() throws -> String {
    try ClaudeHelperSocket.resolve()
}

private func readBoundedStdin() -> Data {
    let limit = ClaudeStatusLineDecoder.maximumPayloadBytes + 1
    var data = Data()
    while data.count < limit {
        let chunk = FileHandle.standardInput.availableData
        if chunk.isEmpty { break }
        data.append(chunk)
    }
    return data
}

private func deliver(_ payload: Data) async throws {
    // Reuses the existing hook envelope transport: a status line is just
    // another bounded provider observation.
    let envelope = try ProviderHookEnvelope(
        provider: .claude,
        rawJSON: payload,
        sourcePID: getpid(),
        ancestors: [],
        observedAt: Date()
    )
    let client = try await UnixDaemonClient.connect(path: try socketPath())
    defer { Task { await client.stop() } }
    _ = try await client.send(.ingestProviderHook(envelope))
}

let payload = readBoundedStdin()

await withTaskGroup(of: Void.self) { group in
    group.addTask {
        // Validate before sending so unparsable bytes never reach the daemon.
        guard (try? ClaudeStatusLineDecoder().decode(payload)) != nil else { return }
        try? await deliver(payload)
    }
    group.addTask {
        try? await Task.sleep(for: endToEndTimeout)
    }

    _ = await group.next()
    group.cancelAll()
}

exit(EXIT_SUCCESS)
