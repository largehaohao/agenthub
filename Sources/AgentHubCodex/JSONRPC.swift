import Foundation

public enum JSONRPCID: Codable, Equatable, Hashable, Sendable {
    case integer(Int64)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "JSON-RPC id must be an integer or string"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .integer(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

public struct JSONRPCErrorObject: Codable, Equatable, Sendable {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public struct JSONRPCMessage: Codable, Equatable, Sendable {
    public var jsonrpc: String?
    public var id: JSONRPCID?
    public var method: String?
    public var params: JSONValue?
    public var result: JSONValue?
    public var error: JSONRPCErrorObject?

    public init(
        jsonrpc: String? = "2.0",
        id: JSONRPCID? = nil,
        method: String? = nil,
        params: JSONValue? = nil,
        result: JSONValue? = nil,
        error: JSONRPCErrorObject? = nil
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.error = error
    }

    public var isServerRequest: Bool {
        id != nil && method != nil
    }
}

public enum CodexRPCError: Error, Equatable, Sendable {
    case malformedMessage
    case transportEnded
    case remote(code: Int, message: String)
    case executableNotFound
    case invalidExecutable(String)
    case processExited(Int32)
    case notStarted
    case alreadyStarted
}

public func decodeRPC(_ data: Data) throws -> JSONRPCMessage {
    do {
        return try JSONDecoder().decode(JSONRPCMessage.self, from: data)
    } catch {
        throw CodexRPCError.malformedMessage
    }
}

public func decodeRPC(_ line: String) throws -> JSONRPCMessage {
    try decodeRPC(Data(line.utf8))
}
