import Foundation
import AgentHubCore

public struct CursorHookHandleResult: Equatable, Sendable {
    public let stdout: Data

    public init(stdout: Data) {
        self.stdout = stdout
    }
}

/// Bridges one Cursor hook invocation to the AgentHub daemon.
///
/// Observation events ingest and return `{}`. Decision events ingest, await an
/// AgentHub allow/deny, and print Cursor's `permission` JSON. Failures always
/// degrade to `ask` so Cursor's native UI remains authoritative.
public struct CursorHookReporter: Sendable {
    public struct Delivery: Equatable, Sendable {
        public let requestID: UUID?

        public init(requestID: UUID?) {
            self.requestID = requestID
        }
    }

    private let send: @Sendable (ProviderHookEnvelope) async throws -> Delivery
    private let awaitPermission: @Sendable (UUID, Int) async -> HookPermissionDecision
    private let timeoutMilliseconds: Int
    private let now: @Sendable () -> Date

    public init(
        send: @escaping @Sendable (ProviderHookEnvelope) async throws -> Delivery,
        awaitPermission: @escaping @Sendable (UUID, Int) async -> HookPermissionDecision,
        timeoutMilliseconds: Int = CursorPermissionGate.defaultTimeoutMilliseconds,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.send = send
        self.awaitPermission = awaitPermission
        self.timeoutMilliseconds = timeoutMilliseconds
        self.now = now
    }

    public func handle(stdin: Data, sourcePID: Int32) async -> CursorHookHandleResult {
        do {
            guard stdin.count <= ProviderHookEnvelope.maximumPayloadBytes else {
                return askResult()
            }
            let payload = try CursorHookDecoder().decode(stdin)
            let envelope = try ProviderHookEnvelope(
                provider: .cursor,
                rawJSON: stdin,
                sourcePID: sourcePID,
                ancestors: [],
                observedAt: now()
            )

            let delivery = try await send(envelope)
            guard payload.requiresPermissionDecision else {
                return CursorHookHandleResult(stdout: Data("{}".utf8))
            }
            guard let requestID = delivery.requestID else {
                return askResult()
            }
            let decision = await awaitPermission(requestID, timeoutMilliseconds)
            return CursorHookHandleResult(
                stdout: CursorPermissionGate.responseJSON(for: decision)
            )
        } catch {
            return askResult()
        }
    }

    private func askResult() -> CursorHookHandleResult {
        CursorHookHandleResult(stdout: CursorPermissionGate.responseJSON(for: .ask))
    }
}
