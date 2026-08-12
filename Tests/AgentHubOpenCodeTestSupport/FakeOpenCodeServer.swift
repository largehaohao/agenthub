import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix

public actor FakeOpenCodeServer {
    public struct Session: Codable, Equatable, Sendable {
        public struct Time: Codable, Equatable, Sendable {
            public let created: Int64
            public let updated: Int64

            public init(created: Int64, updated: Int64) {
                self.created = created
                self.updated = updated
            }
        }

        public let id: String
        public let directory: String
        public let parentID: String?
        public let title: String
        public let version: String
        public let time: Time

        public init(
            id: String,
            directory: String,
            parentID: String? = nil,
            title: String = "Fake OpenCode session",
            version: String = "1.18.10",
            updated: Int64 = 1_700_000_000_000
        ) {
            self.id = id
            self.directory = directory
            self.parentID = parentID
            self.title = title
            self.version = version
            time = Time(created: updated - 1_000, updated: updated)
        }
    }

    public struct Permission: Codable, Equatable, Sendable {
        public let id: String
        public let sessionID: String
        public let permission: String
        public let patterns: [String]
        public let always: [String]

        public init(
            id: String,
            sessionID: String,
            permission: String = "bash",
            patterns: [String] = [],
            always: [String] = []
        ) {
            self.id = id
            self.sessionID = sessionID
            self.permission = permission
            self.patterns = patterns
            self.always = always
        }
    }

    public struct Question: Codable, Equatable, Sendable {
        public struct Field: Codable, Equatable, Sendable {
            public struct Option: Codable, Equatable, Sendable {
                public let label: String
                public let description: String

                public init(label: String, description: String = "") {
                    self.label = label
                    self.description = description
                }
            }

            public let question: String
            public let header: String
            public let options: [Option]
            public let multiple: Bool?
            public let custom: Bool?

            public init(
                question: String,
                header: String,
                options: [Option] = [],
                multiple: Bool = false,
                custom: Bool = false
            ) {
                self.question = question
                self.header = header
                self.options = options
                self.multiple = multiple
                self.custom = custom
            }
        }

        public let id: String
        public let sessionID: String
        public let questions: [Field]

        public init(id: String, sessionID: String, questions: [Field]) {
            self.id = id
            self.sessionID = sessionID
            self.questions = questions
        }
    }

    public struct RecordedRequest: Equatable, Sendable {
        public let method: String
        public let path: String
        public let query: String?
        public let body: String
        public let authorizationPresent: Bool
    }

    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    private let storage: Storage
    public nonisolated let baseURL: String

    public static func start() async throws -> FakeOpenCodeServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let storage = Storage()
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 16)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline().flatMap {
                        channel.pipeline.addHandler(FakeHTTPHandler(storage: storage))
                    }
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            guard let port = channel.localAddress?.port else {
                try await channel.close().get()
                try await shutdown(group)
                throw FakeServerError.missingPort
            }
            return FakeOpenCodeServer(
                group: group,
                channel: channel,
                storage: storage,
                baseURL: "http://127.0.0.1:\(port)"
            )
        } catch {
            try? await shutdown(group)
            throw error
        }
    }

    private init(
        group: MultiThreadedEventLoopGroup,
        channel: Channel,
        storage: Storage,
        baseURL: String
    ) {
        self.group = group
        self.channel = channel
        self.storage = storage
        self.baseURL = baseURL
    }

    public func setSessions(_ sessions: [Session]) { storage.setSessions(sessions) }
    public func setPermissions(_ permissions: [Permission]) { storage.setPermissions(permissions) }
    public func setQuestions(_ questions: [Question]) { storage.setQuestions(questions) }
    public func setHealthy(_ healthy: Bool) { storage.setHealthy(healthy) }
    public func requests() -> [RecordedRequest] { storage.requests() }
    public func prompts() -> [String] { storage.prompts() }
    public func selectedSessions() -> [String] { storage.selectedSessions() }
    public func permissionReplies() -> [String: String] { storage.permissionReplies() }
    public func questionReplies() -> [String: [[String]]] { storage.questionReplies() }

    public func emitEvent(type: String) {
        storage.emitEvent(type: type)
    }

    public func stop() async {
        storage.closeEventChannels()
        try? await channel.close().get()
        try? await shutdown(group)
    }
}

private enum FakeServerError: Error { case missingPort }

private final class Storage: @unchecked Sendable {
    private let lock = NSLock()
    private var sessionsByID: [String: FakeOpenCodeServer.Session] = [:]
    private var permissions: [FakeOpenCodeServer.Permission] = []
    private var questions: [FakeOpenCodeServer.Question] = []
    private var recordedRequests: [FakeOpenCodeServer.RecordedRequest] = []
    private var promptBodies: [String] = []
    private var selectedSessionIDs: [String] = []
    private var permissionReplyValues: [String: String] = [:]
    private var questionReplyValues: [String: [[String]]] = [:]
    private var eventChannels: [ObjectIdentifier: Channel] = [:]
    private var healthy = true
    private var nextSession = 1

    func setSessions(_ sessions: [FakeOpenCodeServer.Session]) {
        lock.withLock { sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) }) }
    }

    func setPermissions(_ value: [FakeOpenCodeServer.Permission]) {
        lock.withLock { permissions = value }
    }

    func setQuestions(_ value: [FakeOpenCodeServer.Question]) {
        lock.withLock { questions = value }
    }

    func setHealthy(_ value: Bool) { lock.withLock { healthy = value } }
    func requests() -> [FakeOpenCodeServer.RecordedRequest] { lock.withLock { recordedRequests } }
    func prompts() -> [String] { lock.withLock { promptBodies } }
    func selectedSessions() -> [String] { lock.withLock { selectedSessionIDs } }
    func permissionReplies() -> [String: String] { lock.withLock { permissionReplyValues } }
    func questionReplies() -> [String: [[String]]] { lock.withLock { questionReplyValues } }

    func handle(head: HTTPRequestHead, body: Data, channel: Channel) -> Response? {
        let components = URLComponents(string: "http://localhost\(head.uri)")
        let path = components?.path ?? head.uri
        let bodyText = String(decoding: body, as: UTF8.self)
        lock.withLock {
            recordedRequests.append(.init(
                method: head.method.rawValue,
                path: path,
                query: components?.percentEncodedQuery,
                body: bodyText,
                authorizationPresent: head.headers.contains(name: "Authorization")
            ))
        }

        if head.method == .GET && path == "/event" {
            lock.withLock { eventChannels[ObjectIdentifier(channel)] = channel }
            return nil
        }
        if head.method == .GET && path == "/global/health" {
            return lock.withLock {
                healthy
                    ? .json(200, #"{"healthy":true,"version":"1.18.10"}"#)
                    : .json(503, #"{"healthy":false,"version":"1.18.10"}"#)
            }
        }
        if head.method == .GET && path == "/session" {
            let sessions = lock.withLock { sessionsByID.values.sorted { $0.id < $1.id } }
            return .encoded(sessions)
        }
        if head.method == .POST && path == "/session" {
            let directory = components?.queryItems?.first { $0.name == "directory" }?.value ?? "/tmp"
            let title = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["title"] as? String
            let session = lock.withLock { () -> FakeOpenCodeServer.Session in
                let value = FakeOpenCodeServer.Session(
                    id: "ses_created_\(nextSession)",
                    directory: directory,
                    title: title ?? "AgentHub managed session",
                    updated: 1_700_000_000_000 + Int64(nextSession)
                )
                nextSession += 1
                sessionsByID[value.id] = value
                return value
            }
            return .encoded(session)
        }
        if head.method == .GET && path == "/session/status" {
            let ids = lock.withLock { Array(sessionsByID.keys) }
            let values = Dictionary(uniqueKeysWithValues: ids.map {
                ($0, Status(type: "idle", attempt: nil, message: nil, next: nil))
            })
            return .encoded(values)
        }
        if path.hasPrefix("/session/") {
            let suffix = String(path.dropFirst("/session/".count))
            if suffix.hasSuffix("/children"), head.method == .GET {
                let id = String(suffix.dropLast("/children".count))
                let children = lock.withLock {
                    sessionsByID.values.filter { $0.parentID == id }.sorted { $0.id < $1.id }
                }
                return .encoded(children)
            }
            if suffix.hasSuffix("/message"), head.method == .GET { return .json(200, "[]") }
            if suffix.hasSuffix("/prompt_async"), head.method == .POST {
                lock.withLock { promptBodies.append(bodyText) }
                return .json(200, "true")
            }
            if head.method == .DELETE {
                _ = lock.withLock { sessionsByID.removeValue(forKey: suffix) }
                return .json(200, "true")
            }
            if head.method == .GET {
                guard let session = lock.withLock({ sessionsByID[suffix] }) else {
                    return .json(404, "{}")
                }
                return .encoded(session)
            }
        }
        if head.method == .GET && path == "/permission" {
            return .encoded(lock.withLock { permissions })
        }
        if head.method == .POST && path.hasPrefix("/permission/") && path.hasSuffix("/reply") {
            let id = String(path.dropFirst("/permission/".count).dropLast("/reply".count))
            let reply = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["reply"] as? String ?? ""
            let found = lock.withLock { () -> Bool in
                guard permissions.contains(where: { $0.id == id }) else { return false }
                permissions.removeAll { $0.id == id }
                permissionReplyValues[id] = reply
                return true
            }
            return .json(found ? 200 : 404, found ? "true" : "{}")
        }
        if head.method == .GET && path == "/question" {
            return .encoded(lock.withLock { questions })
        }
        if head.method == .POST && path.hasPrefix("/question/") && path.hasSuffix("/reply") {
            let id = String(path.dropFirst("/question/".count).dropLast("/reply".count))
            let answers = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["answers"] as? [[String]] ?? []
            let found = lock.withLock { () -> Bool in
                guard questions.contains(where: { $0.id == id }) else { return false }
                questions.removeAll { $0.id == id }
                questionReplyValues[id] = answers
                return true
            }
            return .json(found ? 200 : 404, found ? "true" : "{}")
        }
        if head.method == .POST && path == "/tui/select-session" {
            let id = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["sessionID"] as? String ?? ""
            lock.withLock { selectedSessionIDs.append(id) }
            return .json(200, "true")
        }
        return .json(404, "{}")
    }

    func emitEvent(type: String) {
        let channels = lock.withLock { Array(eventChannels.values) }
        let payload = "data: {\"type\":\"\(type)\",\"properties\":{}}\n\n"
        for channel in channels where channel.isActive {
            var buffer = channel.allocator.buffer(capacity: payload.utf8.count)
            buffer.writeString(payload)
            channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
        }
    }

    func closeEventChannels() {
        let channels = lock.withLock { () -> [Channel] in
            defer { eventChannels.removeAll() }
            return Array(eventChannels.values)
        }
        for channel in channels { channel.close(promise: nil) }
    }
}

private struct Status: Codable { let type: String; let attempt: Int?; let message: String?; let next: Int64? }

private struct Response {
    let status: HTTPResponseStatus
    let body: ByteBuffer

    static func json(_ status: Int, _ body: String) -> Response {
        var buffer = ByteBufferAllocator().buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        return Response(status: .init(statusCode: status), body: buffer)
    }

    static func encoded<Value: Encodable>(_ value: Value) -> Response {
        let data = (try? JSONEncoder().encode(value)) ?? Data("null".utf8)
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return Response(status: .ok, body: buffer)
    }
}

private final class FakeHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let storage: Storage
    private var head: HTTPRequestHead?
    private var body = Data()

    init(storage: Storage) { self.storage = storage }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let value):
            head = value
            body.removeAll(keepingCapacity: true)
        case .body(var buffer):
            body.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
        case .end:
            guard let head else { return }
            if head.method == .GET && URLComponents(string: "http://localhost\(head.uri)")?.path == "/event" {
                _ = storage.handle(head: head, body: body, channel: context.channel)
                var headers = HTTPHeaders()
                headers.add(name: "Content-Type", value: "text/event-stream")
                headers.add(name: "Cache-Control", value: "no-cache")
                context.writeAndFlush(wrapOutboundOut(.head(.init(
                    version: head.version,
                    status: .ok,
                    headers: headers
                ))), promise: nil)
                return
            }
            let response = storage.handle(head: head, body: body, channel: context.channel)
                ?? .json(500, "{}")
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/json")
            headers.add(name: "Content-Length", value: String(response.body.readableBytes))
            context.write(wrapOutboundOut(.head(.init(
                version: head.version,
                status: response.status,
                headers: headers
            ))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(response.body))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

private func shutdown(_ group: MultiThreadedEventLoopGroup) async throws {
    try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        group.shutdownGracefully { error in
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume() }
        }
    }
}
