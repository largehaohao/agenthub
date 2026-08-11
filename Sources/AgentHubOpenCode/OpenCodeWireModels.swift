import Foundation

struct OpenCodeHealth: Codable, Equatable, Sendable {
    let healthy: Bool
    let version: String
}

struct OpenCodeSession: Codable, Equatable, Sendable {
    struct Time: Codable, Equatable, Sendable {
        let created: Int64
        let updated: Int64
    }

    let id: String
    let directory: String
    let parentID: String?
    let title: String
    let version: String
    let time: Time
}

struct OpenCodeSessionStatus: Codable, Equatable, Sendable {
    let type: String
    let attempt: Int?
    let message: String?
    let next: Int64?
}

struct OpenCodeMessage: Codable, Equatable, Sendable {
    let info: OpenCodeMessageInfo
    let parts: [OpenCodeMessagePart]
}

struct OpenCodeMessageInfo: Codable, Equatable, Sendable {
    struct Time: Codable, Equatable, Sendable {
        let created: Int64
        let completed: Int64?
    }

    let id: String
    let sessionID: String
    let role: String
    let time: Time
}

struct OpenCodeMessagePart: Codable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let messageID: String
    let type: String
    let text: String?
}

struct OpenCodePermissionRequest: Codable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let permission: String
    let patterns: [String]
    let always: [String]
}

enum OpenCodePermissionReply: String, Codable, Equatable, Sendable {
    case once
    case always
    case reject
}

struct OpenCodeQuestionRequest: Codable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let questions: [OpenCodeQuestion]
}

struct OpenCodeQuestion: Codable, Equatable, Sendable {
    let question: String
    let header: String
    let options: [OpenCodeQuestionOption]
    let multiple: Bool?
    let custom: Bool?
}

struct OpenCodeQuestionOption: Codable, Equatable, Sendable {
    let label: String
    let description: String
}

struct OpenCodeEvent: Equatable, Sendable {
    let type: String
    let propertiesJSON: Data

    init(type: String, propertiesJSON: Data) {
        self.type = type
        self.propertiesJSON = propertiesJSON
    }

    init(data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            throw OpenCodeWireError.malformedEvent
        }
        let properties = object["properties"] ?? [String: Any]()
        guard JSONSerialization.isValidJSONObject(properties) else {
            throw OpenCodeWireError.malformedEvent
        }
        self.type = type
        propertiesJSON = try JSONSerialization.data(
            withJSONObject: properties,
            options: [.sortedKeys]
        )
    }

    func decodeProperties<Value: Decodable>(
        _ type: Value.Type,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> Value {
        try decoder.decode(type, from: propertiesJSON)
    }
}

enum OpenCodeWireError: Error, Equatable, Sendable {
    case malformedEvent
}
