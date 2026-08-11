import Foundation

public enum Provider: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
    case cursor
    case openCode
}

public enum ReliabilityLevel: Int, Codable, Comparable, Sendable {
    case l1 = 1
    case l2 = 2
    case l3 = 3

    public static func < (lhs: ReliabilityLevel, rhs: ReliabilityLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum Capability: String, Codable, Hashable, Sendable {
    case discover
    case launch
    case status
    case children
    case recentTurns
    case sendInput
    case resolveRequest
    case jump
    case quota
}

public enum SessionStatus: String, Codable, Sendable {
    case starting
    case working
    case waitingPermission
    case waitingInput
    case idle
    case completed
    case error
    case disconnected
}

public enum SessionOwnership: String, Codable, Sendable {
    case managed
    case discovered
}

public enum RequestKind: String, Codable, Sendable {
    case permission
    case planApproval
    case choice
    case textInput
    case confirmation
    case authentication
}

public enum RequestState: String, Codable, Sendable {
    case pending
    case resolving
    case resolved
    case expired
}

public enum DeliveryState: String, Codable, Sendable {
    case queued
    case delivering
    case delivered
    case failed
    case manual
}

public struct ProviderSessionRef: Codable, Hashable, Sendable {
    public let provider: Provider
    public let accountID: String
    public let nativeID: String

    public init(provider: Provider, accountID: String, nativeID: String) {
        self.provider = provider
        self.accountID = accountID
        self.nativeID = nativeID
    }
}

public struct AgentSession: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var providerRef: ProviderSessionRef
    public var title: String
    public var surface: String
    public var ownership: SessionOwnership
    public var status: SessionStatus
    public var rootID: UUID
    public var parentID: UUID?
    public var cwd: String?
    public var repository: String?
    public var branch: String?
    public var lastActivityAt: Date
    public var capabilities: [Capability: ReliabilityLevel]
    public var preview: [VisibleTurn]

    public init(
        id: UUID,
        providerRef: ProviderSessionRef,
        title: String,
        surface: String,
        ownership: SessionOwnership,
        status: SessionStatus,
        rootID: UUID,
        parentID: UUID? = nil,
        cwd: String? = nil,
        repository: String? = nil,
        branch: String? = nil,
        lastActivityAt: Date,
        capabilities: [Capability: ReliabilityLevel],
        preview: [VisibleTurn]
    ) {
        self.id = id
        self.providerRef = providerRef
        self.title = title
        self.surface = surface
        self.ownership = ownership
        self.status = status
        self.rootID = rootID
        self.parentID = parentID
        self.cwd = cwd
        self.repository = repository
        self.branch = branch
        self.lastActivityAt = lastActivityAt
        self.capabilities = capabilities
        self.preview = preview
    }
}

public struct AgentNode: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var sessionID: UUID
    public var nativeID: String
    public var parentNativeID: String?
    public var kind: String
    public var status: SessionStatus
    public var lastActivityAt: Date

    public init(
        id: UUID,
        sessionID: UUID,
        nativeID: String,
        parentNativeID: String? = nil,
        kind: String,
        status: SessionStatus,
        lastActivityAt: Date
    ) {
        self.id = id
        self.sessionID = sessionID
        self.nativeID = nativeID
        self.parentNativeID = parentNativeID
        self.kind = kind
        self.status = status
        self.lastActivityAt = lastActivityAt
    }
}

public struct VisibleTurn: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var role: String
    public var text: String
    public var createdAt: Date

    public init(id: String, role: String, text: String, createdAt: Date) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

public struct PendingRequest: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var provider: Provider
    public var providerRequestID: String
    public var sessionID: UUID
    public var threadID: String
    public var turnID: String?
    public var itemID: String?
    public var kind: RequestKind
    public var title: String
    public var detail: String
    public var allowedActions: [String]
    public var state: RequestState
    public var reliability: ReliabilityLevel
    public var createdAt: Date
    public var expiresAt: Date?

    public init(
        id: UUID,
        provider: Provider,
        providerRequestID: String,
        sessionID: UUID,
        threadID: String,
        turnID: String? = nil,
        itemID: String? = nil,
        kind: RequestKind,
        title: String,
        detail: String,
        allowedActions: [String],
        state: RequestState,
        reliability: ReliabilityLevel,
        createdAt: Date,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.provider = provider
        self.providerRequestID = providerRequestID
        self.sessionID = sessionID
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.kind = kind
        self.title = title
        self.detail = detail
        self.allowedActions = allowedActions
        self.state = state
        self.reliability = reliability
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

public struct MessageEnvelope: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var sourceSessionID: UUID
    public var targetSessionID: UUID
    public var repository: String?
    public var cwd: String?
    public var branch: String?
    public var turns: [VisibleTurn]
    public var userNote: String?
    public var createdAt: Date
    public var expiresAt: Date
    public var state: DeliveryState
    public var failure: String?

    public init(
        id: UUID,
        sourceSessionID: UUID,
        targetSessionID: UUID,
        repository: String? = nil,
        cwd: String? = nil,
        branch: String? = nil,
        turns: [VisibleTurn],
        userNote: String? = nil,
        createdAt: Date,
        expiresAt: Date,
        state: DeliveryState,
        failure: String? = nil
    ) {
        self.id = id
        self.sourceSessionID = sourceSessionID
        self.targetSessionID = targetSessionID
        self.repository = repository
        self.cwd = cwd
        self.branch = branch
        self.turns = turns
        self.userNote = userNote
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.state = state
        self.failure = failure
    }
}

public enum ModelValidationError: Error, Equatable, Sendable {
    case quotaPercentOutOfRange
    case nonPositiveWindowDuration
}

public struct QuotaWindow: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let provider: Provider
    public let accountID: String
    public let usedPercent: Double
    public let windowDuration: TimeInterval
    public let resetsAt: Date
    public let fetchedAt: Date
    public let source: String

    public init(
        provider: Provider,
        accountID: String,
        usedPercent: Double,
        windowDuration: TimeInterval,
        resetsAt: Date,
        fetchedAt: Date,
        source: String
    ) throws {
        guard (0...100).contains(usedPercent) else {
            throw ModelValidationError.quotaPercentOutOfRange
        }
        guard windowDuration > 0 else {
            throw ModelValidationError.nonPositiveWindowDuration
        }

        self.id = "\(provider.rawValue):\(accountID):\(Int(windowDuration))"
        self.provider = provider
        self.accountID = accountID
        self.usedPercent = usedPercent
        self.windowDuration = windowDuration
        self.resetsAt = resetsAt
        self.fetchedAt = fetchedAt
        self.source = source
    }

    public func isStale(now: Date, sourceTTL: TimeInterval? = nil) -> Bool {
        now.timeIntervalSince(fetchedAt) > (sourceTTL ?? 15 * 60)
    }

    public func availablePace(now: Date) -> Double? {
        guard !isStale(now: now) else { return nil }

        let remainingSeconds = resetsAt.timeIntervalSince(now)
        guard remainingSeconds > 0 else { return nil }

        let remainingTimeFraction = min(remainingSeconds / windowDuration, 1)
        let remainingQuotaFraction = max(0, 1 - usedPercent / 100)
        return remainingQuotaFraction / remainingTimeFraction
    }
}

public struct LaunchRequest: Codable, Equatable, Sendable {
    public let clientRequestID: String
    public let cwd: String
    public let prompt: String

    public init(clientRequestID: String, cwd: String, prompt: String) {
        self.clientRequestID = clientRequestID
        self.cwd = cwd
        self.prompt = prompt
    }
}

public struct AdapterSnapshot: Codable, Equatable, Sendable {
    public var sessions: [AgentSession]
    public var nodes: [AgentNode]
    public var requests: [PendingRequest]
    public var quotas: [QuotaWindow]

    public init(
        sessions: [AgentSession],
        nodes: [AgentNode],
        requests: [PendingRequest],
        quotas: [QuotaWindow]
    ) {
        self.sessions = sessions
        self.nodes = nodes
        self.requests = requests
        self.quotas = quotas
    }
}

public struct AgentInput: Codable, Equatable, Sendable {
    public let text: String
    public let provenance: String?

    public init(text: String, provenance: String? = nil) {
        self.text = text
        self.provenance = provenance
    }
}

public struct ProviderRequestRef: Codable, Equatable, Sendable {
    public let provider: Provider
    public let requestID: String
    public let threadID: String
    public let turnID: String?
    public let itemID: String?

    public init(
        provider: Provider,
        requestID: String,
        threadID: String,
        turnID: String? = nil,
        itemID: String? = nil
    ) {
        self.provider = provider
        self.requestID = requestID
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
    }
}

public enum RequestDecision: Codable, Equatable, Sendable {
    case accept
    case acceptForSession
    case decline
    case cancel
    case text(String)
    case choices([String])
}

public enum JumpTarget: Codable, Equatable, Sendable {
    case agentHubDetail(sessionNativeID: String)
    case terminal(pane: String)
    case application(bundleID: String, windowHint: String?)
    case unavailable(String)
}

public enum AgentEvent: Codable, Equatable, Sendable {
    case sessionUpserted(AgentSession)
    case nodeUpserted(AgentNode)
    case requestUpserted(PendingRequest)
    case requestResolutionStarted(id: UUID)
    case requestResolved(id: UUID, outcome: String)
    case envelopeUpserted(MessageEnvelope)
    case quotaUpserted(QuotaWindow)
    case adapterHealth(Provider, AdapterHealth)
}

public struct AdapterHealth: Codable, Equatable, Sendable {
    public var connected: Bool
    public var message: String?
    public var changedAt: Date

    public init(connected: Bool, message: String? = nil, changedAt: Date) {
        self.connected = connected
        self.message = message
        self.changedAt = changedAt
    }
}

public extension JSONEncoder {
    static var agentHub: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

public extension JSONDecoder {
    static var agentHub: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
