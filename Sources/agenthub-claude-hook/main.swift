import Darwin
import Foundation
import AgentHubClaude
import AgentHubCore
import AgentHubIPC

/// One-shot bridge invoked by Claude Code with a hook payload on stdin.
///
/// It always exits zero. A hook must never block Claude or surface an AgentHub
/// failure to the user, so an unavailable daemon, a timeout, or a malformed
/// payload is silently dropped rather than reported as a hook error.
private let endToEndTimeout: Duration = .milliseconds(500)

private func socketPath() throws -> String {
    try ClaudeHelperSocket.resolve()
}

/// Reads at most one maximum payload plus one byte, so an oversized stream is
/// detected without buffering it all.
private func readBoundedStdin() -> Data {
    let limit = ProviderHookEnvelope.maximumPayloadBytes + 1
    var data = Data()
    while data.count < limit {
        let chunk = FileHandle.standardInput.availableData
        if chunk.isEmpty { break }
        data.append(chunk)
    }
    return data
}

private func deliver(_ envelope: ProviderHookEnvelope) async throws {
    let client = try await UnixDaemonClient.connect(path: try socketPath())
    defer { Task { await client.stop() } }
    _ = try await client.send(.ingestProviderHook(envelope))
}

let payload = readBoundedStdin()
let reporter = ClaudeHookReporter(send: deliver)

await withTaskGroup(of: Bool.self) { group in
    group.addTask {
        do {
            try await reporter.report(stdin: payload, sourcePID: getpid())
            return true
        } catch {
            return false
        }
    }
    group.addTask {
        try? await Task.sleep(for: endToEndTimeout)
        return false
    }

    _ = await group.next()
    group.cancelAll()
}

exit(EXIT_SUCCESS)
