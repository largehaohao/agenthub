import Foundation
import AgentHubCore

protocol OpenCodeHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func bytes(
        for request: URLRequest
    ) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse)
}

struct URLSessionOpenCodeHTTPTransport: OpenCodeHTTPTransport, Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw OpenCodeHTTPError.invalidResponse
        }
        return (data, response)
    }

    func bytes(
        for request: URLRequest
    ) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw OpenCodeHTTPError.invalidResponse
        }
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        continuation.yield(Data([byte]))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (stream, response)
    }
}

enum OpenCodeAuthorization: Equatable, Sendable {
    case none
    case basic(username: String, password: String)
}

enum OpenCodeHTTPError: Error, Equatable, Sendable {
    case invalidBaseURL
    case invalidResponse
    case authenticationRequired
    case alreadyResolved
    case httpStatus(Int)
}

protocol OpenCodeAPI: Sendable {
    func health() async throws -> OpenCodeHealth
    func sessions(directory: String?) async throws -> [OpenCodeSession]
    func createSession(
        directory: String,
        title: String?,
        agent: String?,
        model: LaunchModelSelection?
    ) async throws -> OpenCodeSession
    func session(id: String, directory: String?) async throws -> OpenCodeSession
    func deleteSession(id: String, directory: String?) async throws
    func statuses(directory: String?) async throws -> [String: OpenCodeSessionStatus]
    func children(sessionID: String, directory: String?) async throws -> [OpenCodeSession]
    func messages(sessionID: String, directory: String?, limit: Int) async throws -> [OpenCodeMessage]
    func promptAsync(sessionID: String, directory: String, input: AgentInput) async throws
    func permissions(directory: String?) async throws -> [OpenCodePermissionRequest]
    func replyPermission(
        id: String,
        reply: OpenCodePermissionReply,
        message: String?,
        directory: String?
    ) async throws
    func questions(directory: String?) async throws -> [OpenCodeQuestionRequest]
    func replyQuestion(id: String, answers: [[String]], directory: String?) async throws
    func events(directory: String?) async -> AsyncThrowingStream<OpenCodeEvent, Error>
    func selectSession(id: String, directory: String?) async throws
}

struct OpenCodeHTTPClient: OpenCodeAPI, Sendable {
    private let baseURL: URL
    private let authorization: OpenCodeAuthorization
    private let transport: any OpenCodeHTTPTransport
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        baseURL: URL,
        authorization: OpenCodeAuthorization = .none,
        transport: any OpenCodeHTTPTransport = URLSessionOpenCodeHTTPTransport()
    ) {
        self.baseURL = baseURL
        self.authorization = authorization
        self.transport = transport
        encoder.outputFormatting = [.sortedKeys]
    }

    func health() async throws -> OpenCodeHealth {
        try await get(OpenCodeHealth.self, path: "/global/health")
    }

    func sessions(directory: String?) async throws -> [OpenCodeSession] {
        try await get([OpenCodeSession].self, path: "/session", directory: directory)
    }

    func createSession(
        directory: String,
        title: String?,
        agent: String?,
        model: LaunchModelSelection?
    ) async throws -> OpenCodeSession {
        let body = CreateSessionBody(title: title, agent: agent, model: model.map {
            .init(id: $0.modelID, providerID: $0.providerID, variant: $0.variant)
        })
        return try await send(
            OpenCodeSession.self,
            method: "POST",
            path: "/session",
            directory: directory,
            body: body
        )
    }

    func session(id: String, directory: String?) async throws -> OpenCodeSession {
        try await get(OpenCodeSession.self, path: "/session/\(id)", directory: directory)
    }

    func deleteSession(id: String, directory: String?) async throws {
        try await sendWithoutResult(
            method: "DELETE",
            path: "/session/\(id)",
            directory: directory,
            body: Optional<EmptyBody>.none
        )
    }

    func statuses(directory: String?) async throws -> [String: OpenCodeSessionStatus] {
        try await get(
            [String: OpenCodeSessionStatus].self,
            path: "/session/status",
            directory: directory
        )
    }

    func children(sessionID: String, directory: String?) async throws -> [OpenCodeSession] {
        try await get(
            [OpenCodeSession].self,
            path: "/session/\(sessionID)/children",
            directory: directory
        )
    }

    func messages(
        sessionID: String,
        directory: String?,
        limit: Int
    ) async throws -> [OpenCodeMessage] {
        try await get(
            [OpenCodeMessage].self,
            path: "/session/\(sessionID)/message",
            directory: directory,
            query: [URLQueryItem(name: "limit", value: String(max(0, min(limit, 20))))]
        )
    }

    func promptAsync(sessionID: String, directory: String, input: AgentInput) async throws {
        try await sendWithoutResult(
            method: "POST",
            path: "/session/\(sessionID)/prompt_async",
            directory: directory,
            body: PromptBody(parts: [.init(type: "text", text: input.text)])
        )
    }

    func permissions(directory: String?) async throws -> [OpenCodePermissionRequest] {
        try await get(
            [OpenCodePermissionRequest].self,
            path: "/permission",
            directory: directory
        )
    }

    func replyPermission(
        id: String,
        reply: OpenCodePermissionReply,
        message: String?,
        directory: String?
    ) async throws {
        try await sendWithoutResult(
            method: "POST",
            path: "/permission/\(id)/reply",
            directory: directory,
            body: PermissionReplyBody(reply: reply, message: message),
            mapNotFoundToResolved: true
        )
    }

    func questions(directory: String?) async throws -> [OpenCodeQuestionRequest] {
        try await get(
            [OpenCodeQuestionRequest].self,
            path: "/question",
            directory: directory
        )
    }

    func replyQuestion(id: String, answers: [[String]], directory: String?) async throws {
        try await sendWithoutResult(
            method: "POST",
            path: "/question/\(id)/reply",
            directory: directory,
            body: QuestionReplyBody(answers: answers),
            mapNotFoundToResolved: true
        )
    }

    func events(directory: String?) async -> AsyncThrowingStream<OpenCodeEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(
                        method: "GET",
                        path: "/event",
                        directory: directory,
                        query: [],
                        body: nil
                    )
                    let (chunks, response) = try await transport.bytes(for: request)
                    try validate(response)
                    var parser = ServerSentEventParser()
                    for try await chunk in chunks {
                        for frame in try parser.append(chunk) {
                            continuation.yield(try OpenCodeEvent(data: frame.data))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func selectSession(id: String, directory: String?) async throws {
        try await sendWithoutResult(
            method: "POST",
            path: "/tui/select-session",
            directory: directory,
            body: SelectSessionBody(sessionID: id)
        )
    }

    private func get<Value: Decodable>(
        _ type: Value.Type,
        path: String,
        directory: String? = nil,
        query: [URLQueryItem] = []
    ) async throws -> Value {
        let request = try makeRequest(
            method: "GET",
            path: path,
            directory: directory,
            query: query,
            body: nil
        )
        let (data, response) = try await transport.data(for: request)
        try validate(response)
        return try decoder.decode(type, from: data)
    }

    private func send<Value: Decodable, Body: Encodable>(
        _ type: Value.Type,
        method: String,
        path: String,
        directory: String?,
        body: Body
    ) async throws -> Value {
        let request = try makeRequest(
            method: method,
            path: path,
            directory: directory,
            query: [],
            body: try encoder.encode(body)
        )
        let (data, response) = try await transport.data(for: request)
        try validate(response)
        return try decoder.decode(type, from: data)
    }

    private func sendWithoutResult<Body: Encodable>(
        method: String,
        path: String,
        directory: String?,
        body: Body?,
        mapNotFoundToResolved: Bool = false
    ) async throws {
        let request = try makeRequest(
            method: method,
            path: path,
            directory: directory,
            query: [],
            body: try body.map(encoder.encode)
        )
        let (_, response) = try await transport.data(for: request)
        try validate(response, mapNotFoundToResolved: mapNotFoundToResolved)
    }

    private func makeRequest(
        method: String,
        path: String,
        directory: String?,
        query: [URLQueryItem],
        body: Data?
    ) throws -> URLRequest {
        guard baseURL.scheme == "http",
              baseURL.user == nil,
              baseURL.password == nil,
              baseURL.port != nil,
              baseURL.path.isEmpty || baseURL.path == "/",
              baseURL.query == nil,
              baseURL.fragment == nil,
              let host = baseURL.host,
              host == "127.0.0.1" || host == "::1" else {
            throw OpenCodeHTTPError.invalidBaseURL
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw OpenCodeHTTPError.invalidBaseURL
        }
        components.path = path
        var items: [URLQueryItem] = []
        if let directory { items.append(URLQueryItem(name: "directory", value: directory)) }
        items.append(contentsOf: query)
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { throw OpenCodeHTTPError.invalidBaseURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if case .basic(let username, let password) = authorization {
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func validate(
        _ response: HTTPURLResponse,
        mapNotFoundToResolved: Bool = false
    ) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw OpenCodeHTTPError.authenticationRequired
        case 404 where mapNotFoundToResolved:
            throw OpenCodeHTTPError.alreadyResolved
        default:
            throw OpenCodeHTTPError.httpStatus(response.statusCode)
        }
    }
}

private struct EmptyBody: Encodable {}

private struct CreateSessionBody: Encodable {
    struct Model: Encodable {
        let id: String
        let providerID: String
        let variant: String?
    }

    let title: String?
    let agent: String?
    let model: Model?
}

private struct PromptBody: Encodable {
    struct Part: Encodable {
        let type: String
        let text: String
    }

    let parts: [Part]
}

private struct PermissionReplyBody: Encodable {
    let reply: OpenCodePermissionReply
    let message: String?
}

private struct QuestionReplyBody: Encodable {
    let answers: [[String]]
}

private struct SelectSessionBody: Encodable {
    let sessionID: String
}
