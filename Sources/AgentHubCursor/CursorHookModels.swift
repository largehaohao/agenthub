import Foundation

/// Coarse decoding failure. It never carries payload text so a malformed hook
/// cannot leak tool input, prompts, or secrets through an error description.
public enum CursorHookDecodingError: Error, Equatable, Sendable {
    case malformedPayload
}

public enum CursorHookEventName: String, Equatable, Sendable {
    case sessionStart
    case sessionEnd
    case beforeSubmitPrompt
    case stop
    case beforeShellExecution
    case afterShellExecution
    case beforeMCPExecution
    case afterMCPExecution
    case subagentStart
    case subagentStop
    case afterAgentResponse
    case afterAgentThought
    case preCompact
    case unknown
}

/// Normalized, bounded view of a Cursor hook payload.
public struct CursorHookPayload: Equatable, Sendable {
    public static let maximumPreviewBytes = 2_048

    public let event: CursorHookEventName
    public let conversationID: String
    public let generationID: String?
    public let sessionID: String
    public let workspaceRoots: [String]
    public let boundedPreview: String
    public let requiresPermissionDecision: Bool
    public let subagentID: String?
    public let toolName: String?

    public init(
        event: CursorHookEventName,
        conversationID: String,
        generationID: String?,
        sessionID: String,
        workspaceRoots: [String],
        boundedPreview: String,
        requiresPermissionDecision: Bool,
        subagentID: String? = nil,
        toolName: String? = nil
    ) {
        self.event = event
        self.conversationID = conversationID
        self.generationID = generationID
        self.sessionID = sessionID
        self.workspaceRoots = workspaceRoots
        self.boundedPreview = Self.bounded(boundedPreview)
        self.requiresPermissionDecision = requiresPermissionDecision
        self.subagentID = subagentID
        self.toolName = toolName
    }

    public static func bounded(_ text: String) -> String {
        let utf8 = Array(text.utf8)
        guard utf8.count > maximumPreviewBytes else { return text }
        return String(decoding: utf8.prefix(maximumPreviewBytes), as: UTF8.self)
    }
}

public struct CursorHookDecoder: Sendable {
    public init() {}

    public func decode(_ data: Data) throws -> CursorHookPayload {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any] else {
            throw CursorHookDecodingError.malformedPayload
        }

        let eventName = string(json["hook_event_name"])
            ?? string(json["event_name"])
        guard let eventName else {
            throw CursorHookDecodingError.malformedPayload
        }

        let event = CursorHookEventName(rawValue: eventName) ?? .unknown
        let conversationID = string(json["conversation_id"])
            ?? string(json["session_id"])
            ?? ""
        guard !conversationID.isEmpty else {
            throw CursorHookDecodingError.malformedPayload
        }

        let sessionID = string(json["session_id"]) ?? conversationID
        let generationID = string(json["generation_id"])
        let workspaceRoots = stringArray(json["workspace_roots"])
        let requiresDecision = event == .beforeShellExecution
            || event == .beforeMCPExecution

        let toolName = string(json["tool_name"])
        let preview: String
        switch event {
        case .beforeShellExecution:
            preview = string(json["command"]) ?? ""
        case .beforeMCPExecution, .afterMCPExecution:
            let input = string(json["tool_input"]) ?? ""
            preview = [toolName, input]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        case .beforeSubmitPrompt:
            preview = string(json["prompt"]) == nil ? "" : "[prompt]"
        case .subagentStart, .subagentStop:
            preview = [
                string(json["subagent_type"]),
                string(json["subagent_id"]),
            ]
            .compactMap { $0 }
            .joined(separator: " ")
        case .stop, .sessionEnd:
            preview = string(json["status"]) ?? ""
        default:
            preview = eventName
        }

        return CursorHookPayload(
            event: event,
            conversationID: conversationID,
            generationID: generationID,
            sessionID: sessionID,
            workspaceRoots: workspaceRoots,
            boundedPreview: preview,
            requiresPermissionDecision: requiresDecision,
            subagentID: string(json["subagent_id"]),
            toolName: toolName
        )
    }

    private func string(_ value: Any?) -> String? {
        value as? String
    }

    private func stringArray(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }
}
