import Foundation
import AgentHubCore
import AgentHubIPC

enum ConnectionState: Equatable, Sendable {
    case connecting
    case connected
    case disconnected(String)
}

protocol DaemonClientProtocol: Sendable {
    func connect() async throws
    func send(_ command: DaemonCommand) async throws -> DaemonReply
    func events() async -> AsyncStream<DaemonEvent>
}

actor DaemonClient: DaemonClientProtocol {
    private let socketPath: String
    private let eventStream: AsyncStream<DaemonEvent>
    private let eventContinuation: AsyncStream<DaemonEvent>.Continuation
    private var connection: UnixDaemonClient?
    private var relay: Task<Void, Never>?

    init(socketPath: String) {
        self.socketPath = socketPath
        let pair = AsyncStream<DaemonEvent>.makeStream()
        eventStream = pair.stream
        eventContinuation = pair.continuation
    }

    func connect() async throws {
        guard connection == nil else { return }
        let connection = try await UnixDaemonClient.connect(path: socketPath)
        self.connection = connection
        let upstream = connection.events
        relay = Task { [eventContinuation] in
            for await event in upstream {
                eventContinuation.yield(event)
            }
        }
    }

    func send(_ command: DaemonCommand) async throws -> DaemonReply {
        guard let connection else { throw IPCError.disconnected }
        return try await connection.send(command)
    }

    func events() async -> AsyncStream<DaemonEvent> {
        eventStream
    }
}
