import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
import AgentHubCore

public actor UnixDaemonClient {
    public nonisolated let events: AsyncStream<DaemonEvent>
    public private(set) var negotiatedProtocolVersion: Int?

    private let path: String
    private let group: MultiThreadedEventLoopGroup
    private let eventContinuation: AsyncStream<DaemonEvent>.Continuation
    private var channel: Channel?
    private var pending: [UUID: CheckedContinuation<DaemonReply, Error>] = [:]
    private var stopped = false
    private var reconnecting = false

    private init(path: String, group: MultiThreadedEventLoopGroup) {
        self.path = path
        self.group = group
        let pair = AsyncStream<DaemonEvent>.makeStream()
        events = pair.stream
        eventContinuation = pair.continuation
    }

    public static func connect(path: String) async throws -> UnixDaemonClient {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = UnixDaemonClient(path: path, group: group)
        do {
            try await client.connectNow()
            return client
        } catch {
            try? await shutdown(group)
            throw error
        }
    }

    public func send(_ command: DaemonCommand) async throws -> DaemonReply {
        guard let channel, channel.isActive else { throw IPCError.disconnected }
        let requestID = UUID()
        let envelope = IPCEnvelope(requestID: requestID, body: command)
        let encoded = try JSONLineCodec.encode(envelope)
        var buffer = channel.allocator.buffer(capacity: encoded.count)
        buffer.writeJSONLine(encoded)

        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = continuation
            channel.writeAndFlush(buffer).whenFailure { [weak self] error in
                guard let self else { return }
                Task { await self.failRequest(requestID, error: error) }
            }
        }
    }

    public func stop() async {
        guard !stopped else { return }
        stopped = true
        reconnecting = false
        if let channel {
            try? await channel.close().get()
        }
        channel = nil
        failAll(with: IPCError.disconnected)
        eventContinuation.finish()
        try? await shutdown(group)
    }

    private func connectNow() async throws {
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { [weak self] channel in
                guard let self else {
                    return channel.eventLoop.makeFailedFuture(IPCError.disconnected)
                }
                do {
                    try channel.pipeline.syncOperations.addHandler(
                        ByteToMessageHandler(JSONLineFrameDecoder())
                    )
                    try channel.pipeline.syncOperations.addHandler(
                        ClientInboundHandler(client: self)
                    )
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
        channel = try await bootstrap.connect(unixDomainSocketPath: path).get()
    }

    fileprivate func receive(_ data: Data) {
        do {
            let envelope = try JSONDecoder.agentHub.decode(
                IPCEnvelope<WireBody>.self,
                from: data
            )
            try JSONLineCodec.validate(protocolVersion: envelope.protocolVersion)
            negotiatedProtocolVersion = envelope.protocolVersion
            switch envelope.body {
            case .reply(let reply):
                pending.removeValue(forKey: envelope.requestID)?.resume(returning: reply)
            case .event(let event):
                eventContinuation.yield(event)
            }
        } catch {
            failAll(with: error)
        }
    }

    fileprivate func disconnected() {
        channel = nil
        failAll(with: IPCError.disconnected)
        guard !stopped, !reconnecting else { return }
        reconnecting = true
        Task { await reconnectLoop() }
    }

    private func reconnectLoop() async {
        var attempt = 0
        while !stopped, channel == nil {
            let base = ReconnectSchedule.delays[min(attempt, ReconnectSchedule.delays.count - 1)]
            let jitter = Double.random(in: -0.1...0.1) * base
            try? await Task.sleep(for: .seconds(base + jitter))
            guard !stopped else { break }
            do {
                try await connectNow()
            } catch {
                attempt += 1
            }
        }
        reconnecting = false
    }

    private func failRequest(_ id: UUID, error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failAll(with error: Error) {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }
}

private final class ClientInboundHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let client: UnixDaemonClient

    init(client: UnixDaemonClient) {
        self.client = client
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var frame = unwrapInboundIn(data)
        let bytes = frame.readData()
        Task { await client.receive(bytes) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        Task { await client.disconnected() }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
