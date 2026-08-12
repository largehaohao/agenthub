import Darwin
import Foundation
import AgentHubCore
import AgentHubCursor
import AgentHubIPC

/// One-shot bridge invoked by Cursor with a hook payload on stdin.
///
/// Decision hooks wait for AgentHub; observation hooks return quickly. The
/// process always exits zero and never default-allows a tool call.
private let endToEndTimeout: Duration = .seconds(30)

private func socketPath() throws -> String {
    try DaemonSocketPath.resolve()
}

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

private func deliver(_ envelope: ProviderHookEnvelope) async throws -> CursorHookReporter.Delivery {
    let client = try await UnixDaemonClient.connect(path: try socketPath())
    defer { Task { await client.stop() } }
    let reply = try await client.send(.ingestProviderHook(envelope))
    if case .accepted(let id) = reply {
        return .init(requestID: id)
    }
    return .init(requestID: nil)
}

private func awaitPermission(requestID: UUID, timeoutMilliseconds: Int) async -> HookPermissionDecision {
    do {
        let client = try await UnixDaemonClient.connect(path: try socketPath())
        defer { Task { await client.stop() } }
        let reply = try await client.send(
            .awaitHookPermission(
                requestID: requestID,
                timeoutMilliseconds: timeoutMilliseconds
            )
        )
        if case .hookPermission(let decision) = reply {
            return decision
        }
        return .ask
    } catch {
        return .ask
    }
}

let payload = readBoundedStdin()
let reporter = CursorHookReporter(send: deliver, awaitPermission: awaitPermission)

let result = await withTaskGroup(of: CursorHookHandleResult.self) { group in
    group.addTask {
        await reporter.handle(stdin: payload, sourcePID: getpid())
    }
    group.addTask {
        try? await Task.sleep(for: endToEndTimeout)
        return CursorHookHandleResult(
            stdout: CursorPermissionGate.responseJSON(for: .ask)
        )
    }
    let first = await group.next()!
    group.cancelAll()
    return first
}

FileHandle.standardOutput.write(result.stdout)
exit(EXIT_SUCCESS)
