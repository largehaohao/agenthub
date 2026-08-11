import Foundation

public protocol LineTransport: Sendable {
    func start() async throws
    func send(line: Data) async throws
    func lines() async -> AsyncThrowingStream<Data, Error>
    func stop() async
}

public actor CodexRPCClient {
    private let transport: any LineTransport
    private let messageStream: AsyncStream<JSONRPCMessage>
    private let messageContinuation: AsyncStream<JSONRPCMessage>.Continuation
    private var pending: [JSONRPCID: CheckedContinuation<JSONValue, Error>] = [:]
    private var nextID: Int64 = 1
    private var readTask: Task<Void, Never>?
    private var terminalError: CodexRPCError?
    private var started = false

    public init(transport: any LineTransport) {
        self.transport = transport
        let pair = AsyncStream<JSONRPCMessage>.makeStream()
        messageStream = pair.stream
        messageContinuation = pair.continuation
    }

    public func start(clientName: String, clientVersion: String) async throws {
        guard !started else { throw CodexRPCError.alreadyStarted }
        started = true
        do {
            try await transport.start()
            ensureReader()
            _ = try await call(
                method: "initialize",
                params: .object([
                    "clientInfo": .object([
                        "name": .string(clientName),
                        "version": .string(clientVersion),
                    ]),
                ])
            )
            try await sendMessage(JSONRPCMessage(method: "initialized"))
        } catch {
            started = false
            await transport.stop()
            terminate(with: error)
            throw error
        }
    }

    public func call(method: String, params: JSONValue?) async throws -> JSONValue {
        if let terminalError { throw terminalError }
        ensureReader()
        let id = JSONRPCID.integer(nextID)
        nextID += 1
        let message = JSONRPCMessage(id: id, method: method, params: params)
        let encoded = try JSONEncoder().encode(message)

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { [transport] in
                do {
                    try await transport.send(line: encoded)
                } catch {
                    self.fail(id: id, error: error)
                }
            }
        }
    }

    public func respond(id: JSONRPCID, result: JSONValue) async throws {
        try await sendMessage(JSONRPCMessage(id: id, result: result))
    }

    public func messages() -> AsyncStream<JSONRPCMessage> {
        ensureReader()
        return messageStream
    }

    public func stop() async {
        readTask?.cancel()
        readTask = nil
        await transport.stop()
        terminate(with: CodexRPCError.transportEnded)
    }

    private func sendMessage(_ message: JSONRPCMessage) async throws {
        if let terminalError { throw terminalError }
        try await transport.send(line: JSONEncoder().encode(message))
    }

    private func ensureReader() {
        guard readTask == nil, terminalError == nil else { return }
        let transport = transport
        readTask = Task {
            let lines = await transport.lines()
            do {
                for try await line in lines {
                    guard self.consume(line) else { return }
                }
                self.terminate(with: CodexRPCError.transportEnded)
            } catch {
                self.terminate(with: error)
            }
        }
    }

    private func consume(_ line: Data) -> Bool {
        let message: JSONRPCMessage
        do {
            message = try decodeRPC(line)
        } catch {
            terminate(with: CodexRPCError.malformedMessage)
            return false
        }

        if let id = message.id, message.method == nil {
            guard let continuation = pending.removeValue(forKey: id) else { return true }
            if let error = message.error {
                continuation.resume(
                    throwing: CodexRPCError.remote(code: error.code, message: error.message)
                )
            } else if let result = message.result {
                continuation.resume(returning: result)
            } else {
                continuation.resume(throwing: CodexRPCError.malformedMessage)
            }
        } else if message.method != nil {
            messageContinuation.yield(message)
        }
        return true
    }

    private func fail(id: JSONRPCID, error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func terminate(with error: Error) {
        guard terminalError == nil else { return }
        let normalized = error as? CodexRPCError ?? .transportEnded
        terminalError = normalized
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: normalized)
        }
        messageContinuation.finish()
    }
}
