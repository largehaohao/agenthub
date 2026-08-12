import Foundation

public enum Provider: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
    case cursor
    case openCode
}

public struct ProcessObservation: Codable, Equatable, Sendable {
    public let pid: Int32
    public let parentPID: Int32
    public let uid: UInt32
    public let tty: String?
    public let command: String

    public init(pid: Int32, parentPID: Int32, uid: UInt32, tty: String?, command: String) {
        self.pid = pid
        self.parentPID = parentPID
        self.uid = uid
        self.tty = tty
        self.command = command
    }
}

public enum ProviderHookEnvelopeError: Error, Equatable, Sendable {
    case oversizedPayload
}

public struct ProviderHookEnvelope: Codable, Equatable, Sendable {
    public static let maximumPayloadBytes = 256 * 1_024

    public let provider: Provider
    public let rawJSON: Data
    public let sourcePID: Int32
    public let ancestors: [ProcessObservation]
    public let observedAt: Date

    public init(
        provider: Provider,
        rawJSON: Data,
        sourcePID: Int32,
        ancestors: [ProcessObservation],
        observedAt: Date
    ) throws {
        guard rawJSON.count <= Self.maximumPayloadBytes else {
            throw ProviderHookEnvelopeError.oversizedPayload
        }

        self.provider = provider
        self.rawJSON = rawJSON
        self.sourcePID = sourcePID
        self.ancestors = ancestors
        self.observedAt = observedAt
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case rawJSON
        case sourcePID
        case ancestors
        case observedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            provider: container.decode(Provider.self, forKey: .provider),
            rawJSON: container.decode(Data.self, forKey: .rawJSON),
            sourcePID: container.decode(Int32.self, forKey: .sourcePID),
            ancestors: container.decode([ProcessObservation].self, forKey: .ancestors),
            observedAt: container.decode(Date.self, forKey: .observedAt)
        )
    }
}

public struct ProviderComponentStatus: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(provider.rawValue):\(component)" }

    public let provider: Provider
    public let component: String
    public let available: Bool
    public let version: String?
    public let path: String?
    public let message: String?
    public let changedAt: Date

    public init(
        provider: Provider,
        component: String,
        available: Bool,
        version: String?,
        path: String?,
        message: String?,
        changedAt: Date
    ) {
        self.provider = provider
        self.component = component
        self.available = available
        self.version = version
        self.path = path
        self.message = message
        self.changedAt = changedAt
    }
}

public enum ProviderConfigurationAction: String, Codable, Sendable {
    case installHooks, uninstallHooks, refreshComponents
    case installQuotaHelper, refreshQuota
}

public enum NativeInteractionOperation: Codable, Equatable, Sendable {
    case choose(label: String)
    case enter(text: String)
}

public struct NativeInteractionPlan: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let provider: Provider
    public let requestID: UUID
    public let bundleID: String
    public let windowHint: String?
    public let sessionNativeID: String
    public let promptFingerprint: String
    public let operation: NativeInteractionOperation

    public init(
        id: UUID,
        provider: Provider,
        requestID: UUID,
        bundleID: String,
        windowHint: String?,
        sessionNativeID: String,
        promptFingerprint: String,
        operation: NativeInteractionOperation
    ) {
        self.id = id
        self.provider = provider
        self.requestID = requestID
        self.bundleID = bundleID
        self.windowHint = windowHint
        self.sessionNativeID = sessionNativeID
        self.promptFingerprint = promptFingerprint
        self.operation = operation
    }
}

public enum RequestResolutionRoute: Codable, Equatable, Sendable {
    case provider
    case native(NativeInteractionPlan)
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

public enum ProviderEndpointOrigin: String, Codable, Sendable {
    case managed
    case desktop
    case tui
    case manual
}

public struct ProviderEndpoint: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let provider: Provider
    public let origin: ProviderEndpointOrigin
    public let baseURL: String
    public let credentialReference: String?
    public var connected: Bool
    public var version: String?
    public var message: String?
    public var lastSeenAt: Date

    public init(
        id: String,
        provider: Provider,
        origin: ProviderEndpointOrigin,
        baseURL: String,
        credentialReference: String? = nil,
        connected: Bool,
        version: String? = nil,
        message: String? = nil,
        lastSeenAt: Date
    ) {
        self.id = id
        self.provider = provider
        self.origin = origin
        self.baseURL = baseURL
        self.credentialReference = credentialReference
        self.connected = connected
        self.version = version
        self.message = message
        self.lastSeenAt = lastSeenAt
    }
}

public struct ProviderEndpointAttachment: Codable, Equatable, Sendable {
    public let provider: Provider
    public let baseURL: String
    public let credentialReference: String?

    public init(
        provider: Provider,
        baseURL: String,
        credentialReference: String? = nil
    ) {
        self.provider = provider
        self.baseURL = baseURL
        self.credentialReference = credentialReference
    }
}

public struct ProviderEndpointCredentialBinding: Codable, Equatable, Sendable {
    public let provider: Provider
    public let endpointID: String
    public let credentialReference: String

    public init(provider: Provider, endpointID: String, credentialReference: String) {
        self.provider = provider
        self.endpointID = endpointID
        self.credentialReference = credentialReference
    }
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

public struct RequestField: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let prompt: String
    public let choices: [String]
    public let allowsMultiple: Bool
    public let allowsFreeText: Bool

    public init(
        id: String,
        prompt: String,
        choices: [String] = [],
        allowsMultiple: Bool = false,
        allowsFreeText: Bool = false
    ) {
        self.id = id
        self.prompt = prompt
        self.choices = choices
        self.allowsMultiple = allowsMultiple
        self.allowsFreeText = allowsFreeText
    }
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
    public var fields: [RequestField]
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
        fields: [RequestField] = [],
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
        self.fields = fields
        self.state = state
        self.reliability = reliability
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, provider, providerRequestID, sessionID, threadID, turnID, itemID
        case kind, title, detail, allowedActions, fields, state, reliability
        case createdAt, expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        provider = try container.decode(Provider.self, forKey: .provider)
        providerRequestID = try container.decode(String.self, forKey: .providerRequestID)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        threadID = try container.decode(String.self, forKey: .threadID)
        turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
        itemID = try container.decodeIfPresent(String.self, forKey: .itemID)
        kind = try container.decode(RequestKind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decode(String.self, forKey: .detail)
        allowedActions = try container.decode([String].self, forKey: .allowedActions)
        fields = try container.decodeIfPresent([RequestField].self, forKey: .fields) ?? []
        state = try container.decode(RequestState.self, forKey: .state)
        reliability = try container.decode(ReliabilityLevel.self, forKey: .reliability)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
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
    /// Source-provided window key. A provider may report several windows that
    /// share a duration (an overall five-hour window and a per-model one), so
    /// this participates in `id` to keep them distinct.
    public let windowID: String?
    public let label: String?
    public let plan: String?
    public let usedPercent: Double
    public let windowDuration: TimeInterval
    public let resetsAt: Date
    public let fetchedAt: Date
    public let source: String

    public init(
        provider: Provider,
        accountID: String,
        windowID: String? = nil,
        label: String? = nil,
        plan: String? = nil,
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

        // Unnamed windows keep the original identity so existing Codex rows
        // continue to match after this field was introduced.
        let base = "\(provider.rawValue):\(accountID):\(Int(windowDuration))"
        self.id = windowID.map { "\(base):\($0)" } ?? base
        self.provider = provider
        self.accountID = accountID
        self.windowID = windowID
        self.label = label
        self.plan = plan
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

public struct LaunchModelSelection: Codable, Equatable, Sendable {
    public let providerID: String
    public let modelID: String
    public let variant: String?

    public init(providerID: String, modelID: String, variant: String? = nil) {
        self.providerID = providerID
        self.modelID = modelID
        self.variant = variant
    }
}

public struct LaunchRequest: Codable, Equatable, Sendable {
    public let clientRequestID: String
    public let cwd: String
    public let prompt: String
    public let agent: String?
    public let model: LaunchModelSelection?

    public init(
        clientRequestID: String,
        cwd: String,
        prompt: String,
        agent: String? = nil,
        model: LaunchModelSelection? = nil
    ) {
        self.clientRequestID = clientRequestID
        self.cwd = cwd
        self.prompt = prompt
        self.agent = agent
        self.model = model
    }
}

public struct AdapterSnapshot: Codable, Equatable, Sendable {
    public var sessions: [AgentSession]
    public var nodes: [AgentNode]
    public var requests: [PendingRequest]
    public var quotas: [QuotaWindow]
    public var endpoints: [ProviderEndpoint]
    public var requestsAreAuthoritative: Bool

    public init(
        sessions: [AgentSession],
        nodes: [AgentNode],
        requests: [PendingRequest],
        quotas: [QuotaWindow],
        endpoints: [ProviderEndpoint] = [],
        requestsAreAuthoritative: Bool = false
    ) {
        self.sessions = sessions
        self.nodes = nodes
        self.requests = requests
        self.quotas = quotas
        self.endpoints = endpoints
        self.requestsAreAuthoritative = requestsAreAuthoritative
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
    case answers([[String]])
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
    case requestExpired(id: UUID)
    case envelopeUpserted(MessageEnvelope)
    case quotaUpserted(QuotaWindow)
    case adapterHealth(Provider, AdapterHealth)
    case endpointUpserted(ProviderEndpoint)
    case endpointRemoved(String)
    case componentUpserted(ProviderComponentStatus)
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
