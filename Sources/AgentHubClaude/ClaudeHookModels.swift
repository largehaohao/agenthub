import Foundation

/// Coarse decoding failure. It never carries payload text so a malformed hook
/// cannot leak tool input, prompts, or secrets through an error description.
public enum ClaudeHookDecodingError: Error, Equatable, Sendable {
    case malformedPayload
}

/// Recursive JSON value used to tolerate additive Claude hook fields. It stays
/// internal so arbitrary provider JSON never escapes this module.
enum ClaudeJSONValue: Decodable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ClaudeJSONValue])
    case object([String: ClaudeJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ClaudeJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: ClaudeJSONValue].self) {
            self = .object(value)
        } else {
            throw ClaudeHookDecodingError.malformedPayload
        }
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var arrayValue: [ClaudeJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var objectValue: [String: ClaudeJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }
}

/// Fields every supported Claude hook event carries.
public struct ClaudeHookCommon: Equatable, Sendable {
    public let eventName: String
    public let sessionID: String
    public let transcriptPath: String
    public let cwd: String
}

public struct ClaudeSessionStart: Equatable, Sendable {
    public let common: ClaudeHookCommon
    public let source: String?
}

public struct ClaudeSessionEnd: Equatable, Sendable {
    public let common: ClaudeHookCommon
    public let reason: String?
}

public struct ClaudeUserPromptSubmit: Equatable, Sendable {
    public let common: ClaudeHookCommon
}

public struct ClaudeStop: Equatable, Sendable {
    public let common: ClaudeHookCommon
    public let lastAssistantMessage: String?
}

public struct ClaudeStopFailure: Equatable, Sendable {
    public let common: ClaudeHookCommon
    public let reason: String?
}

public struct ClaudeQuestionOption: Equatable, Sendable {
    public let label: String
    public let detail: String?
}

public struct ClaudeQuestion: Equatable, Sendable {
    public let prompt: String
    public let header: String?
    public let allowsMultipleSelections: Bool
    public let options: [ClaudeQuestionOption]
}

public struct ClaudeToolUse: Equatable, Sendable {
    public let common: ClaudeHookCommon
    public let toolName: String
    public let questions: [ClaudeQuestion]
}

public struct ClaudeToolResult: Equatable, Sendable {
    public let common: ClaudeHookCommon
    public let toolName: String
}

public struct ClaudePermissionRequest: Equatable, Sendable {
    public let common: ClaudeHookCommon
    public let toolName: String
    public let options: [String]
}

public struct ClaudePermissionDenied: Equatable, Sendable {
    public let common: ClaudeHookCommon
    public let toolName: String
}

public struct ClaudeNotification: Equatable, Sendable {
    public let common: ClaudeHookCommon
    public let notificationType: String?
    public let message: String?
}

public struct ClaudeSubagentStart: Equatable, Sendable {
    public let common: ClaudeHookCommon
    public let agentID: String
    public let agentType: String?
    public let description: String?
}

public struct ClaudeSubagentStop: Equatable, Sendable {
    public let common: ClaudeHookCommon
    public let agentID: String
    public let agentType: String?
}

public struct ClaudeTaskCreated: Equatable, Sendable {
    public let common: ClaudeHookCommon
    public let taskID: String
    public let description: String?
}

public struct ClaudeTaskCompleted: Equatable, Sendable {
    public let common: ClaudeHookCommon
    public let taskID: String
    public let status: String?
}

public struct ClaudeTeammateIdle: Equatable, Sendable {
    public let common: ClaudeHookCommon
    public let agentID: String?
}

public enum ClaudeHookEvent: Equatable, Sendable {
    case sessionStart(ClaudeSessionStart)
    case sessionEnd(ClaudeSessionEnd)
    case userPromptSubmit(ClaudeUserPromptSubmit)
    case stop(ClaudeStop)
    case stopFailure(ClaudeStopFailure)
    case preToolUse(ClaudeToolUse)
    case postToolUse(ClaudeToolResult)
    case permissionRequest(ClaudePermissionRequest)
    case permissionDenied(ClaudePermissionDenied)
    case notification(ClaudeNotification)
    case subagentStart(ClaudeSubagentStart)
    case subagentStop(ClaudeSubagentStop)
    case taskCreated(ClaudeTaskCreated)
    case taskCompleted(ClaudeTaskCompleted)
    case teammateIdle(ClaudeTeammateIdle)
    case unknown(String)
}

/// Decodes Claude hook payloads into a bounded, typed vocabulary. Unsupported
/// event names decode to `.unknown` so a newer Claude release never breaks
/// ingestion, while known events require their identifying fields.
public struct ClaudeHookDecoder: Sendable {
    public init() {}

    public func decode(_ data: Data) throws -> ClaudeHookEvent {
        let decoded = try? JSONDecoder().decode(ClaudeJSONValue.self, from: data)
        guard let object = decoded?.objectValue,
              let eventName = object["hook_event_name"]?.stringValue else {
            throw ClaudeHookDecodingError.malformedPayload
        }

        // An unsupported event never needs common fields; report it by name only.
        guard let known = KnownEvent(rawValue: eventName) else {
            return .unknown(eventName)
        }

        let common = try commonFields(eventName: eventName, in: object)

        switch known {
        case .sessionStart:
            return .sessionStart(.init(common: common, source: object["source"]?.stringValue))

        case .sessionEnd:
            return .sessionEnd(.init(common: common, reason: object["reason"]?.stringValue))

        case .userPromptSubmit:
            return .userPromptSubmit(.init(common: common))

        case .stop:
            return .stop(.init(
                common: common,
                lastAssistantMessage: object["last_assistant_message"]?.stringValue
            ))

        case .stopFailure:
            return .stopFailure(.init(common: common, reason: object["reason"]?.stringValue))

        case .preToolUse:
            let toolName = try requiredString(object["tool_name"])
            return .preToolUse(.init(
                common: common,
                toolName: toolName,
                questions: questions(in: object["tool_input"])
            ))

        case .postToolUse:
            return .postToolUse(.init(
                common: common,
                toolName: try requiredString(object["tool_name"])
            ))

        case .permissionRequest:
            return .permissionRequest(.init(
                common: common,
                toolName: try requiredString(object["tool_name"]),
                options: object["permission_suggestions"]?
                    .arrayValue?
                    .compactMap(\.stringValue) ?? []
            ))

        case .permissionDenied:
            return .permissionDenied(.init(
                common: common,
                toolName: try requiredString(object["tool_name"])
            ))

        case .notification:
            return .notification(.init(
                common: common,
                notificationType: object["notification_type"]?.stringValue,
                message: object["message"]?.stringValue
            ))

        case .subagentStart:
            return .subagentStart(.init(
                common: common,
                agentID: try requiredString(object["agent_id"]),
                agentType: object["agent_type"]?.stringValue,
                description: object["description"]?.stringValue
            ))

        case .subagentStop:
            return .subagentStop(.init(
                common: common,
                agentID: try requiredString(object["agent_id"]),
                agentType: object["agent_type"]?.stringValue
            ))

        case .taskCreated:
            return .taskCreated(.init(
                common: common,
                taskID: try requiredString(object["task_id"]),
                description: object["description"]?.stringValue
            ))

        case .taskCompleted:
            return .taskCompleted(.init(
                common: common,
                taskID: try requiredString(object["task_id"]),
                status: object["status"]?.stringValue
            ))

        case .teammateIdle:
            return .teammateIdle(.init(
                common: common,
                agentID: object["agent_id"]?.stringValue
            ))
        }
    }

    private func commonFields(
        eventName: String,
        in object: [String: ClaudeJSONValue]
    ) throws -> ClaudeHookCommon {
        ClaudeHookCommon(
            eventName: eventName,
            sessionID: try requiredString(object["session_id"]),
            transcriptPath: try requiredString(object["transcript_path"]),
            cwd: try requiredString(object["cwd"])
        )
    }

    private func requiredString(_ value: ClaudeJSONValue?) throws -> String {
        guard let string = value?.stringValue, !string.isEmpty else {
            throw ClaudeHookDecodingError.malformedPayload
        }
        return string
    }

    /// Reads `AskUserQuestion` structure while preserving the order Claude
    /// presented, so an answer index always maps back to the same question.
    private func questions(in toolInput: ClaudeJSONValue?) -> [ClaudeQuestion] {
        guard let entries = toolInput?.objectValue?["questions"]?.arrayValue else { return [] }

        return entries.compactMap { entry in
            guard let object = entry.objectValue,
                  let prompt = object["question"]?.stringValue else { return nil }

            let options = object["options"]?.arrayValue?.compactMap { option -> ClaudeQuestionOption? in
                guard let optionObject = option.objectValue,
                      let label = optionObject["label"]?.stringValue else { return nil }
                return ClaudeQuestionOption(
                    label: label,
                    detail: optionObject["description"]?.stringValue
                )
            } ?? []

            return ClaudeQuestion(
                prompt: prompt,
                header: object["header"]?.stringValue,
                allowsMultipleSelections: object["multiSelect"]?.boolValue ?? false,
                options: options
            )
        }
    }

    private enum KnownEvent: String {
        case sessionStart = "SessionStart"
        case sessionEnd = "SessionEnd"
        case userPromptSubmit = "UserPromptSubmit"
        case stop = "Stop"
        case stopFailure = "StopFailure"
        case preToolUse = "PreToolUse"
        case postToolUse = "PostToolUse"
        case permissionRequest = "PermissionRequest"
        case permissionDenied = "PermissionDenied"
        case notification = "Notification"
        case subagentStart = "SubagentStart"
        case subagentStop = "SubagentStop"
        case taskCreated = "TaskCreated"
        case taskCompleted = "TaskCompleted"
        case teammateIdle = "TeammateIdle"
    }
}
