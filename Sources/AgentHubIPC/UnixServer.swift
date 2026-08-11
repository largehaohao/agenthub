import Dispatch
import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
import AgentHubCore

public actor UnixDaemonServer {
    public typealias CommandHandler = @Sendable (DaemonCommand) async -> DaemonReply

    private let path: String
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    private let connections: ServerConnections
    private var stopped = false

    private init(
        path: String,
        group: MultiThreadedEventLoopGroup,
        channel: Channel,
        connections: ServerConnections
    ) {
        self.path = path
        self.group = group
        self.channel = channel
        self.connections = connections
    }

    public static func bind(
        path: String,
        handler: @escaping CommandHandler
    ) async throws -> UnixDaemonServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let connections = ServerConnections()
        do {
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 16)
                .childChannelInitializer { channel in
                    do {
                        try channel.pipeline.syncOperations.addHandler(
                            ByteToMessageHandler(JSONLineFrameDecoder())
                        )
                        try channel.pipeline.syncOperations.addHandler(ServerInboundHandler(
                            commandHandler: handler,
                            connections: connections
                        ))
                        return channel.eventLoop.makeSucceededVoidFuture()
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
            let channel = try await bootstrap.bind(
                unixDomainSocketPath: path,
                cleanupExistingSocketFile: true
            ).get()

            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: path
            )
            let mode = try socketMode(path)
            guard mode & 0o777 == 0o600 else {
                try await channel.close().get()
                throw IPCError.invalidSocketPermissions(mode & 0o777)
            }
            return UnixDaemonServer(
                path: path,
                group: group,
                channel: channel,
                connections: connections
            )
        } catch {
            try? await shutdown(group)
            throw error
        }
    }

    public func broadcast(_ event: DaemonEvent) async {
        do {
            let envelope = IPCEnvelope(
                requestID: UUID(),
                body: WireBody.event(event)
            )
            let data = try JSONLineCodec.encode(envelope)
            connections.broadcast(data)
        } catch {
            return
        }
    }

    public func stop() async {
        guard !stopped else { return }
        stopped = true
        try? await channel.close().get()
        await connections.closeAll()
        try? await shutdown(group)
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}

private final class ServerInboundHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let commandHandler: UnixDaemonServer.CommandHandler
    private let connections: ServerConnections

    init(
        commandHandler: @escaping UnixDaemonServer.CommandHandler,
        connections: ServerConnections
    ) {
        self.commandHandler = commandHandler
        self.connections = connections
    }

    func channelActive(context: ChannelHandlerContext) {
        connections.add(context.channel)
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        connections.remove(context.channel)
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var frame = unwrapInboundIn(data)
        let bytes = frame.readData()
        let channel = context.channel
        Task {
            do {
                let envelope = try JSONDecoder.agentHub.decode(
                    IPCEnvelope<DaemonCommand>.self,
                    from: bytes
                )
                try JSONLineCodec.validate(protocolVersion: envelope.protocolVersion)
                let reply = await commandHandler(envelope.body)
                let response = IPCEnvelope(
                    requestID: envelope.requestID,
                    body: WireBody.reply(reply)
                )
                let encoded = try JSONLineCodec.encode(response)
                var buffer = channel.allocator.buffer(capacity: encoded.count)
                buffer.writeJSONLine(encoded)
                try await channel.writeAndFlush(buffer).get()
            } catch {
                try? await channel.close().get()
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

private final class ServerConnections: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.agenthub.ipc.server-connections")
    private var channels: [ObjectIdentifier: Channel] = [:]

    func add(_ channel: Channel) {
        queue.async { [self] in
            channels[ObjectIdentifier(channel)] = channel
        }
    }

    func remove(_ channel: Channel) {
        queue.async { [self] in
            channels.removeValue(forKey: ObjectIdentifier(channel))
        }
    }

    func broadcast(_ data: Data) {
        queue.async { [self] in
            for channel in channels.values where channel.isActive {
                var buffer = channel.allocator.buffer(capacity: data.count)
                buffer.writeJSONLine(data)
                channel.writeAndFlush(buffer, promise: nil)
            }
        }
    }

    func closeAll() async {
        let current = queue.sync { Array(channels.values) }
        for channel in current {
            try? await channel.close().get()
        }
        queue.sync { channels.removeAll() }
    }
}

private func socketMode(_ path: String) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    guard let number = attributes[.posixPermissions] as? NSNumber else {
        throw CocoaError(.fileReadUnknown)
    }
    return number.intValue
}

func shutdown(_ group: MultiThreadedEventLoopGroup) async throws {
    try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        group.shutdownGracefully { error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }
}
