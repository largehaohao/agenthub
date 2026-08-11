import Foundation
import AgentHubCore

enum CodexAdapterError: Error, Equatable {
    case malformedResponse(String)
}

struct CodexThread {
    let id: String
    let sessionID: String
    let name: String?
    let preview: String
    let cwd: String
    let parentThreadID: String?
    let status: SessionStatus
    let updatedAt: Date
    let branch: String?

    init(_ value: JSONValue) throws {
        guard let id = value["id"]?.stringValue,
              let sessionID = value["sessionId"]?.stringValue,
              let cwd = value["cwd"]?.stringValue,
              let updatedAt = value["updatedAt"]?.numberValue else {
            throw CodexAdapterError.malformedResponse("thread")
        }
        self.id = id
        self.sessionID = sessionID
        name = value["name"]?.stringValue
        preview = value["preview"]?.stringValue ?? ""
        self.cwd = cwd
        parentThreadID = value["parentThreadId"]?.stringValue
        status = Self.mapStatus(value["status"])
        self.updatedAt = Date(timeIntervalSince1970: updatedAt)
        branch = value["gitInfo"]?["branch"]?.stringValue
    }

    static func mapStatus(_ value: JSONValue?) -> SessionStatus {
        let type = value?["type"]?.stringValue
        if type == "active" {
            let flags = value?["activeFlags"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if flags.contains("waitingOnApproval") { return .waitingPermission }
            if flags.contains("waitingOnUserInput") { return .waitingInput }
            return .working
        }
        switch type {
        case "idle": return .idle
        case "systemError": return .error
        case "notLoaded": return .disconnected
        default: return .disconnected
        }
    }
}

extension JSONValue {
    var numberValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }
}

func stableCodexUUID(_ value: String) -> UUID {
    if let uuid = UUID(uuidString: value) { return uuid }
    var first: UInt64 = 0xcbf29ce484222325
    var second: UInt64 = 0x84222325cbf29ce4
    for byte in value.utf8 {
        first = (first ^ UInt64(byte)) &* 0x100000001b3
        second = (second ^ UInt64(byte)) &* 0x9e3779b185ebca87
    }
    var bytes = withUnsafeBytes(of: first.bigEndian, Array.init)
        + withUnsafeBytes(of: second.bigEndian, Array.init)
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}
