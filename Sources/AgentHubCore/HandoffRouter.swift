import Foundation

public enum HandoffEligibility: Equatable, Sendable {
    case deliverNow
    case queue
    case blockedByRequest
    case manualOnly(String)
}

public enum AdapterOperationError: Error, Equatable, Sendable {
    case requestAlreadyResolved
    case unsupportedDecision
}

public enum HandoffRouter {
    public static func eligibility(
        target: AgentSession,
        pendingRequests: [PendingRequest]
    ) -> HandoffEligibility {
        let hasBlockingRequest = pendingRequests.contains {
            $0.sessionID == target.id && ($0.state == .pending || $0.state == .resolving)
        }
        if hasBlockingRequest { return .blockedByRequest }

        guard target.capabilities[.sendInput] != nil else {
            return .manualOnly("Target does not support managed input")
        }
        switch target.status {
        case .idle:
            return .deliverNow
        case .starting, .working:
            return .queue
        case .waitingPermission, .waitingInput:
            return .blockedByRequest
        case .completed, .error, .disconnected:
            return .manualOnly("Target is not available for managed delivery")
        }
    }

    public static func render(_ envelope: MessageEnvelope, source: AgentSession) -> String {
        var sections = [
            "AgentHub handoff from \(source.title)",
            "Provider: \(source.providerRef.provider.rawValue)",
        ]
        if let repository = envelope.repository { sections.append("Repository: \(repository)") }
        if let cwd = envelope.cwd { sections.append("Working directory: \(cwd)") }
        if let branch = envelope.branch { sections.append("Branch: \(branch)") }
        if let note = envelope.userNote, !note.isEmpty {
            sections.append("User note: \(note)")
        }
        sections.append("Recent visible turns:")
        sections.append(contentsOf: envelope.turns.suffix(20).map {
            "[\($0.role)] \($0.text)"
        })
        return sections.joined(separator: "\n")
    }
}
