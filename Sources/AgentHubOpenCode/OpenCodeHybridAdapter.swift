import Foundation
import AgentHubCore
import AgentHubSecurity

public enum OpenCodeAdapterError: Error, Equatable, Sendable {
    case staleRoute
    case invalidProvider
    case endpointNotFound
    case unsupportedEndpoint
}

public actor OpenCodeHybridAdapter: EndpointConfigurableAdapter, QuotaForceRefreshing {
    public nonisolated let provider: Provider = .openCode

    private let accountID: String
    private let registry: OpenCodeEndpointRegistry
    private let managedServer: any ManagedOpenCodeServing
    private let discovery: any OpenCodeEndpointDiscovering
    private let credentialStore: any CredentialStoring
    /// Subscription usage for OpenCode Go, rate-limited so `reconcile()` does
    /// not call an external service on every session change.
    private let goQuotaCache: OpenCodeGoQuotaCache?
    private let clientFactory: @Sendable (OpenCodeRuntimeEndpoint) -> any OpenCodeAPI
    private let now: @Sendable () -> Date
    private let events: AsyncStream<AgentEvent>
    private let eventContinuation: AsyncStream<AgentEvent>.Continuation

    private var endpointsByID: [String: OpenCodeRuntimeEndpoint] = [:]
    private var directoryByNativeID: [String: String] = [:]
    private var launchedByClientRequestID: [String: ProviderSessionRef] = [:]
    private var requestKindByID: [String: OpenCodeRequestKind] = [:]
    private var restoredCredentialReferences: [String: String] = [:]
    private var relayTasks: [String: Task<Void, Never>] = [:]
    private var eventRelayStarted = false
    private var authoritativeRequestIDs = Set<UUID>()
    private var lastEmittedRequests: [UUID: PendingRequest] = [:]
    private var lastEmittedSessions: [UUID: AgentSession] = [:]
    private var lastEmittedNodes: [UUID: AgentNode] = [:]

    public init(
        accountID: String = "local-default",
        registry: OpenCodeEndpointRegistry,
        managedServer: any ManagedOpenCodeServing,
        discovery: any OpenCodeEndpointDiscovering,
        credentialStore: any CredentialStoring,
        goQuotaCache: OpenCodeGoQuotaCache? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.accountID = accountID
        self.registry = registry
        self.managedServer = managedServer
        self.discovery = discovery
        self.credentialStore = credentialStore
        self.goQuotaCache = goQuotaCache
        clientFactory = Self.makeHTTPClient
        self.now = now
        let pair = AsyncStream<AgentEvent>.makeStream()
        events = pair.stream
        eventContinuation = pair.continuation
    }

    init(
        accountID: String = "local-default",
        registry: OpenCodeEndpointRegistry,
        managedServer: any ManagedOpenCodeServing,
        discovery: any OpenCodeEndpointDiscovering,
        credentialStore: any CredentialStoring,
        clientFactory: @escaping @Sendable (OpenCodeRuntimeEndpoint) -> any OpenCodeAPI,
        // Defaults to nil so unit tests never reach the live usage endpoint.
        goQuotaCache: OpenCodeGoQuotaCache? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.accountID = accountID
        self.registry = registry
        self.managedServer = managedServer
        self.discovery = discovery
        self.credentialStore = credentialStore
        self.goQuotaCache = goQuotaCache
        self.clientFactory = clientFactory
        self.now = now
        let pair = AsyncStream<AgentEvent>.makeStream()
        events = pair.stream
        eventContinuation = pair.continuation
    }

    public func capabilities() async -> [Capability: ReliabilityLevel] {
        [
            .discover: .l1,
            .launch: .l1,
            .status: .l1,
            .children: .l1,
            .recentTurns: .l1,
            .sendInput: .l1,
            .resolveRequest: .l1,
            .jump: .l1,
        ]
    }

    public func launch(_ request: LaunchRequest) async throws -> ProviderSessionRef {
        if let existing = launchedByClientRequestID[request.clientRequestID] {
            return existing
        }
        let endpoint = try await managedServer.ensureRunning()
        endpointsByID[endpoint.id] = endpoint
        await registry.upsert(endpoint)
        let client = try client(for: endpoint)
        let created = try await client.createSession(
            directory: request.cwd,
            title: nil,
            agent: request.agent,
            model: request.model
        )
        let reference = ProviderSessionRef(
            provider: .openCode,
            accountID: accountID,
            nativeID: created.id
        )
        launchedByClientRequestID[request.clientRequestID] = reference
        directoryByNativeID[created.id] = created.directory
        await registry.observe(
            sessionID: created.id,
            directory: created.directory,
            endpointID: endpoint.id,
            at: now()
        )
        try await client.promptAsync(
            sessionID: created.id,
            directory: created.directory,
            input: AgentInput(text: request.prompt, provenance: "AgentHub launch")
        )
        return reference
    }

    /// Bypasses the usage-API rate limit for an explicit user refresh, so the
    /// refresh button is never a no-op inside the throttle interval.
    public func forceQuotaRefresh() async {
        _ = await goQuotaCache?.windows(force: true)
    }

    public func reconcile() async throws -> AdapterSnapshot {
        try await refreshDiscoveredEndpoints()
        var candidatesByNativeID: [String: [SessionCandidate]] = [:]
        var requestsByProviderID: [String: PendingRequest] = [:]

        for endpoint in endpointsByID.values.sorted(by: { $0.id < $1.id })
        where endpoint.summary.connected {
            do {
                let client = try client(for: endpoint)
                let health = try await client.health()
                guard health.healthy else { continue }
                let listed = try await client.sessions(directory: nil)
                let statuses = try await client.statuses(directory: nil)
                var sessionsByID = Dictionary(uniqueKeysWithValues: listed.map { ($0.id, $0) })
                for root in listed where root.parentID == nil {
                    for child in try await client.children(
                        sessionID: root.id,
                        directory: root.directory
                    ) {
                        sessionsByID[child.id] = child
                    }
                }

                for session in sessionsByID.values {
                    directoryByNativeID[session.id] = session.directory
                    await registry.observe(
                        sessionID: session.id,
                        directory: session.directory,
                        endpointID: endpoint.id,
                        at: date(milliseconds: session.time.updated)
                    )
                    let preview: [VisibleTurn]
                    if session.parentID == nil {
                        let messages = try await client.messages(
                            sessionID: session.id,
                            directory: session.directory,
                            limit: 20
                        )
                        preview = Array(makeTurns(messages, limit: 20).prefix(3))
                    } else {
                        preview = []
                    }
                    candidatesByNativeID[session.id, default: []].append(
                        SessionCandidate(
                            session: session,
                            status: mapStatus(statuses[session.id]),
                            endpoint: endpoint,
                            preview: preview
                        )
                    )
                }
                for permission in try await client.permissions(directory: nil) {
                    guard let directory = directoryByNativeID[permission.sessionID] else { continue }
                    await registry.observe(
                        sessionID: permission.sessionID,
                        directory: directory,
                        endpointID: endpoint.id,
                        at: now()
                    )
                    requestKindByID[permission.id] = .permission
                    requestsByProviderID[permission.id] = makePermissionRequest(permission)
                }
                for question in try await client.questions(directory: nil) {
                    guard let directory = directoryByNativeID[question.sessionID] else { continue }
                    await registry.observe(
                        sessionID: question.sessionID,
                        directory: directory,
                        endpointID: endpoint.id,
                        at: now()
                    )
                    requestKindByID[question.id] = .question
                    requestsByProviderID[question.id] = makeQuestionRequest(question)
                }
            } catch {
                await markEndpointDisconnected(endpoint.id)
            }
        }

        // Only an endpoint the user attached themselves earns an inbox prompt.
        // A discovered server that wants a password is a fact about the machine:
        // the request regenerates on every reconcile and cannot be dismissed, so
        // it would sit in the inbox permanently. Such endpoints are still listed,
        // just as not connected, and can be authenticated from OpenCode Settings.
        for endpoint in endpointsByID.values
        where !endpoint.summary.connected
            && endpoint.summary.message == "authenticationRequired"
            && endpoint.summary.origin == .manual {
            let requestID = "authenticate:\(endpoint.id)"
            requestsByProviderID[requestID] = PendingRequest(
                id: stableOpenCodeUUID(accountID: accountID, nativeID: "request:\(requestID)"),
                provider: .openCode,
                providerRequestID: requestID,
                sessionID: stableOpenCodeUUID(accountID: accountID, nativeID: "endpoint:\(endpoint.id)"),
                threadID: endpoint.id,
                kind: .authentication,
                title: "OpenCode authentication required",
                detail: endpoint.summary.baseURL,
                allowedActions: ["authenticate"],
                state: .pending,
                reliability: .l1,
                createdAt: now()
            )
        }

        let newestByNativeID = candidatesByNativeID.compactMapValues {
            $0.max { $0.session.time.updated < $1.session.time.updated }
        }
        let rootCandidates = newestByNativeID.values
            .filter { $0.session.parentID == nil }
            .sorted { $0.session.time.updated > $1.session.time.updated }
        var sessions: [AgentSession] = []
        for candidate in rootCandidates {
            let nativeID = candidate.session.id
            let id = stableOpenCodeUUID(accountID: accountID, nativeID: nativeID)
            let surfaces = await registry.surfaces(sessionID: nativeID)
            sessions.append(AgentSession(
                id: id,
                providerRef: ProviderSessionRef(
                    provider: .openCode,
                    accountID: accountID,
                    nativeID: nativeID
                ),
                title: candidate.session.title,
                surface: surfaceLabel(surfaces),
                ownership: surfaces.contains(.managed) ? .managed : .discovered,
                status: candidate.status,
                rootID: id,
                cwd: candidate.session.directory,
                lastActivityAt: date(milliseconds: candidate.session.time.updated),
                capabilities: await capabilities(),
                preview: candidate.preview
            ))
        }
        let rootIDByNativeID = Dictionary(
            uniqueKeysWithValues: sessions.map { ($0.providerRef.nativeID, $0.id) }
        )
        let wireByNativeID = newestByNativeID.mapValues(\.session)
        let nodes = newestByNativeID.values.compactMap { candidate -> AgentNode? in
            guard let parentID = candidate.session.parentID else { return nil }
            let rootNativeID = findRootNativeID(
                from: parentID,
                sessionsByNativeID: wireByNativeID
            )
            let rootID = rootIDByNativeID[rootNativeID]
                ?? stableOpenCodeUUID(accountID: accountID, nativeID: rootNativeID)
            return AgentNode(
                id: stableOpenCodeUUID(accountID: accountID, nativeID: candidate.session.id),
                sessionID: rootID,
                nativeID: candidate.session.id,
                parentNativeID: parentID,
                kind: "subagent",
                status: candidate.status,
                lastActivityAt: date(milliseconds: candidate.session.time.updated)
            )
        }.sorted { $0.lastActivityAt > $1.lastActivityAt }

        let requests = requestsByProviderID.values.sorted {
            $0.providerRequestID < $1.providerRequestID
        }
        authoritativeRequestIDs = Set(requests.map(\.id))
        if eventRelayStarted {
            startRelaysForHealthyEndpoints()
        }
        return AdapterSnapshot(
            sessions: sessions,
            nodes: nodes,
            requests: requests,
            quotas: await goQuotaCache?.windows() ?? [],
            endpoints: endpointsByID.values.map(\.summary).sorted { $0.id < $1.id },
            requestsAreAuthoritative: true
        )
    }

    public func eventStream() async -> AsyncStream<AgentEvent> {
        if !eventRelayStarted {
            eventRelayStarted = true
            startRelaysForHealthyEndpoints()
        }
        return events
    }

    public func shutdown() async {
        for task in relayTasks.values { task.cancel() }
        relayTasks.removeAll()
        eventContinuation.finish()
        await managedServer.stop()
    }

    public func recentTurns(
        for session: ProviderSessionRef,
        limit: Int
    ) async throws -> [VisibleTurn] {
        let route = try await exactRoute(for: session, operation: .read)
        let messages = try await client(for: route).messages(
            sessionID: session.nativeID,
            directory: try directory(for: session),
            limit: min(max(limit, 0), 20)
        )
        return makeTurns(messages, limit: limit)
    }

    public func send(_ input: AgentInput, to session: ProviderSessionRef) async throws {
        let route = try await exactRoute(for: session, operation: .send)
        try await client(for: route).promptAsync(
            sessionID: session.nativeID,
            directory: try directory(for: session),
            input: input
        )
    }

    public func resolve(
        _ request: ProviderRequestRef,
        decision: RequestDecision
    ) async throws {
        guard request.provider == .openCode,
              let directory = directoryByNativeID[request.threadID],
              let route = await registry.route(
                sessionID: request.threadID,
                directory: directory,
                operation: .resolveRequest
              ),
              let kind = requestKindByID[request.requestID] else {
            throw OpenCodeAdapterError.staleRoute
        }
        let api = try client(for: route)
        do {
            switch kind {
            case .permission:
                let reply: OpenCodePermissionReply
                switch decision {
                case .accept: reply = .once
                case .acceptForSession: reply = .always
                case .decline, .cancel: reply = .reject
                case .text, .choices, .answers:
                    throw AdapterOperationError.unsupportedDecision
                }
                try await api.replyPermission(
                    id: request.requestID,
                    reply: reply,
                    message: nil,
                    directory: directory
                )
            case .question:
                let answers: [[String]]
                switch decision {
                case .answers(let ordered): answers = ordered
                case .choices(let choices): answers = [choices]
                case .text(let text): answers = [[text]]
                case .accept, .acceptForSession, .decline, .cancel:
                    throw AdapterOperationError.unsupportedDecision
                }
                try await api.replyQuestion(
                    id: request.requestID,
                    answers: answers,
                    directory: directory
                )
            }
        } catch OpenCodeHTTPError.alreadyResolved {
            throw AdapterOperationError.requestAlreadyResolved
        }
    }

    public func jumpTarget(for session: ProviderSessionRef) async -> JumpTarget {
        guard let directory = directoryByNativeID[session.nativeID],
              let route = await registry.route(
                sessionID: session.nativeID,
                directory: directory,
                operation: .jump
        ) else {
            return .unavailable("OpenCode route is stale")
        }
        do {
            try await client(for: route).selectSession(
                id: session.nativeID,
                directory: directory
            )
        } catch {
            if let bundleID = route.applicationBundleID {
                return .application(
                    bundleID: bundleID,
                    windowHint: "OpenCode \(session.nativeID)"
                )
            }
            return .agentHubDetail(sessionNativeID: session.nativeID)
        }
        if let bundleID = route.applicationBundleID {
            return .application(
                bundleID: bundleID,
                windowHint: "OpenCode \(session.nativeID)"
            )
        }
        if let tty = route.terminalTTY {
            return .terminal(pane: tty)
        }
        return .agentHubDetail(sessionNativeID: session.nativeID)
    }

    public func restoreEndpoint(_ endpoint: ProviderEndpoint) async throws {
        guard endpoint.provider == .openCode else { throw OpenCodeAdapterError.invalidProvider }
        guard endpoint.origin != .managed else { throw OpenCodeAdapterError.unsupportedEndpoint }
        _ = try OpenCodeManualEndpointValidator.validate(endpoint.baseURL)
        if endpoint.origin == .desktop || endpoint.origin == .tui {
            if let reference = endpoint.credentialReference {
                restoredCredentialReferences[endpoint.id] = reference
            }
            return
        }
        let runtime = OpenCodeRuntimeEndpoint(
            summary: endpoint,
            credential: endpoint.credentialReference.map {
                .keychain(username: "opencode", reference: $0)
            } ?? .none,
            processID: nil,
            applicationBundleID: nil,
            terminalTTY: nil
        )
        endpointsByID[endpoint.id] = runtime
        await registry.upsert(runtime)
    }

    public func attachEndpoint(
        _ attachment: ProviderEndpointAttachment
    ) async throws -> ProviderEndpoint {
        guard attachment.provider == .openCode else { throw OpenCodeAdapterError.invalidProvider }
        let url = try OpenCodeManualEndpointValidator.validate(attachment.baseURL)
        let endpointID = stableOpenCodeUUID(
            accountID: accountID,
            nativeID: "endpoint:\(url.absoluteString)"
        ).uuidString.lowercased()
        let credential: OpenCodeCredential = attachment.credentialReference.map {
            .keychain(username: "opencode", reference: $0)
        } ?? .none
        var runtime = OpenCodeRuntimeEndpoint(
            summary: ProviderEndpoint(
                id: endpointID,
                provider: .openCode,
                origin: .manual,
                baseURL: url.absoluteString,
                credentialReference: attachment.credentialReference,
                connected: false,
                lastSeenAt: now()
            ),
            credential: credential,
            processID: nil,
            applicationBundleID: nil,
            terminalTTY: nil
        )
        let health = try await client(for: runtime).health()
        runtime.summary.connected = health.healthy
        runtime.summary.version = health.version
        endpointsByID[runtime.id] = runtime
        await registry.upsert(runtime)
        return runtime.summary
    }

    public func authenticateEndpoint(
        _ binding: ProviderEndpointCredentialBinding
    ) async throws -> ProviderEndpoint {
        guard binding.provider == .openCode else { throw OpenCodeAdapterError.invalidProvider }
        guard let existing = endpointsByID[binding.endpointID] else {
            throw OpenCodeAdapterError.endpointNotFound
        }
        _ = try credentialStore.read(reference: binding.credentialReference)
        var summary = existing.summary
        summary = ProviderEndpoint(
            id: summary.id,
            provider: summary.provider,
            origin: summary.origin,
            baseURL: summary.baseURL,
            credentialReference: binding.credentialReference,
            connected: false,
            version: summary.version,
            message: nil,
            lastSeenAt: now()
        )
        var runtime = OpenCodeRuntimeEndpoint(
            summary: summary,
            credential: .keychain(username: "opencode", reference: binding.credentialReference),
            processID: existing.processID,
            applicationBundleID: existing.applicationBundleID,
            terminalTTY: existing.terminalTTY
        )
        let health = try await client(for: runtime).health()
        runtime.summary.connected = health.healthy
        runtime.summary.version = health.version
        endpointsByID[runtime.id] = runtime
        restoredCredentialReferences[runtime.id] = binding.credentialReference
        await registry.upsert(runtime)
        return runtime.summary
    }

    public func detachEndpoint(id: String) async throws {
        guard let existing = endpointsByID[id] else {
            if restoredCredentialReferences.removeValue(forKey: id) != nil { return }
            throw OpenCodeAdapterError.endpointNotFound
        }
        restoredCredentialReferences.removeValue(forKey: id)
        if existing.summary.origin == .manual {
            endpointsByID.removeValue(forKey: id)
            await registry.remove(endpointID: id)
            return
        }
        let summary = ProviderEndpoint(
            id: existing.summary.id,
            provider: existing.summary.provider,
            origin: existing.summary.origin,
            baseURL: existing.summary.baseURL,
            connected: false,
            version: existing.summary.version,
            message: "authenticationRequired",
            lastSeenAt: now()
        )
        let runtime = OpenCodeRuntimeEndpoint(
            summary: summary,
            credential: .none,
            processID: existing.processID,
            applicationBundleID: existing.applicationBundleID,
            terminalTTY: existing.terminalTTY
        )
        endpointsByID[id] = runtime
        await registry.upsert(runtime)
    }

    private struct SessionCandidate {
        let session: OpenCodeSession
        let status: SessionStatus
        let endpoint: OpenCodeRuntimeEndpoint
        let preview: [VisibleTurn]
    }

    private enum OpenCodeRequestKind {
        case permission
        case question
    }

    private func refreshDiscoveredEndpoints() async throws {
        for discovered in try await discovery.discover() {
            let endpoint: OpenCodeRuntimeEndpoint
            if let existing = endpointsByID[discovered.id],
               case .keychain = existing.credential {
                let summary = ProviderEndpoint(
                    id: discovered.summary.id,
                    provider: discovered.summary.provider,
                    origin: discovered.summary.origin,
                    baseURL: discovered.summary.baseURL,
                    credentialReference: existing.summary.credentialReference,
                    connected: true,
                    version: discovered.summary.version,
                    message: nil,
                    lastSeenAt: discovered.summary.lastSeenAt
                )
                endpoint = OpenCodeRuntimeEndpoint(
                    summary: summary,
                    credential: existing.credential,
                    processID: discovered.processID,
                    applicationBundleID: discovered.applicationBundleID,
                    terminalTTY: discovered.terminalTTY
                )
            } else if let reference = restoredCredentialReferences[discovered.id] {
                let summary = ProviderEndpoint(
                    id: discovered.summary.id,
                    provider: discovered.summary.provider,
                    origin: discovered.summary.origin,
                    baseURL: discovered.summary.baseURL,
                    credentialReference: reference,
                    connected: true,
                    version: discovered.summary.version,
                    message: nil,
                    lastSeenAt: discovered.summary.lastSeenAt
                )
                endpoint = OpenCodeRuntimeEndpoint(
                    summary: summary,
                    credential: .keychain(username: "opencode", reference: reference),
                    processID: discovered.processID,
                    applicationBundleID: discovered.applicationBundleID,
                    terminalTTY: discovered.terminalTTY
                )
            } else {
                endpoint = discovered
            }
            endpointsByID[endpoint.id] = endpoint
            await registry.upsert(endpoint)
        }
    }

    private func exactRoute(
        for session: ProviderSessionRef,
        operation: OpenCodeOperation
    ) async throws -> OpenCodeRuntimeEndpoint {
        guard session.provider == .openCode,
              session.accountID == accountID,
              let directory = directoryByNativeID[session.nativeID],
              let route = await registry.route(
                sessionID: session.nativeID,
                directory: directory,
                operation: operation
              ) else {
            throw OpenCodeAdapterError.staleRoute
        }
        return route
    }

    private func directory(for session: ProviderSessionRef) throws -> String {
        guard let directory = directoryByNativeID[session.nativeID] else {
            throw OpenCodeAdapterError.staleRoute
        }
        return directory
    }

    private func client(for endpoint: OpenCodeRuntimeEndpoint) throws -> any OpenCodeAPI {
        switch endpoint.credential {
        case .none, .ephemeral:
            return clientFactory(endpoint)
        case .keychain(let username, let reference):
            let password = try credentialStore.read(reference: reference)
            return clientFactory(OpenCodeRuntimeEndpoint(
                summary: endpoint.summary,
                credential: .ephemeral(username: username, password: password),
                processID: endpoint.processID,
                applicationBundleID: endpoint.applicationBundleID,
                terminalTTY: endpoint.terminalTTY
            ))
        }
    }

    private func makeTurns(_ messages: [OpenCodeMessage], limit: Int) -> [VisibleTurn] {
        let cappedLimit = min(max(limit, 0), 20)
        return messages.prefix(cappedLimit).map { message in
            var seenParts = Set<String>()
            let text = message.parts.compactMap { part -> String? in
                guard part.type == "text",
                      seenParts.insert(part.id).inserted else { return nil }
                return part.text
            }.joined(separator: "\n")
            return VisibleTurn(
                id: message.info.id,
                role: message.info.role,
                text: text,
                createdAt: date(milliseconds: message.info.time.created)
            )
        }
    }

    private func makePermissionRequest(
        _ permission: OpenCodePermissionRequest
    ) -> PendingRequest {
        PendingRequest(
            id: stableOpenCodeUUID(
                accountID: accountID,
                nativeID: "request:\(permission.id)"
            ),
            provider: .openCode,
            providerRequestID: permission.id,
            sessionID: stableOpenCodeUUID(accountID: accountID, nativeID: permission.sessionID),
            threadID: permission.sessionID,
            kind: .permission,
            title: "OpenCode permission request",
            detail: ([permission.permission] + permission.patterns).joined(separator: " · "),
            allowedActions: ["once", "always", "reject"],
            state: .pending,
            reliability: .l1,
            createdAt: now()
        )
    }

    private func makeQuestionRequest(_ question: OpenCodeQuestionRequest) -> PendingRequest {
        PendingRequest(
            id: stableOpenCodeUUID(
                accountID: accountID,
                nativeID: "request:\(question.id)"
            ),
            provider: .openCode,
            providerRequestID: question.id,
            sessionID: stableOpenCodeUUID(accountID: accountID, nativeID: question.sessionID),
            threadID: question.sessionID,
            kind: .choice,
            title: "OpenCode question",
            detail: question.questions.map(\.header).joined(separator: " · "),
            allowedActions: ["answer", "cancel"],
            fields: question.questions.enumerated().map { index, field in
                RequestField(
                    id: String(index),
                    prompt: field.question,
                    choices: field.options.map(\.label),
                    allowsMultiple: field.multiple ?? false,
                    allowsFreeText: field.custom ?? false
                )
            },
            state: .pending,
            reliability: .l1,
            createdAt: now()
        )
    }

    private func mapStatus(_ status: OpenCodeSessionStatus?) -> SessionStatus {
        switch status?.type.lowercased() {
        case "busy", "retry": .working
        case "idle": .idle
        case "error": .error
        default: .completed
        }
    }

    private func findRootNativeID(
        from nativeID: String,
        sessionsByNativeID: [String: OpenCodeSession]
    ) -> String {
        var current = nativeID
        var visited = Set<String>()
        while visited.insert(current).inserted,
              let parent = sessionsByNativeID[current]?.parentID {
            current = parent
        }
        return current
    }

    private func surfaceLabel(_ origins: [ProviderEndpointOrigin]) -> String {
        if origins == [.desktop, .tui] { return "OpenCode Desktop · TUI" }
        return origins.map {
            switch $0 {
            case .managed: "AgentHub Managed"
            case .desktop: "OpenCode Desktop"
            case .tui: "OpenCode TUI"
            case .manual: "OpenCode Manual"
            }
        }.joined(separator: " · ")
    }

    private func startRelaysForHealthyEndpoints() {
        for endpoint in endpointsByID.values
        where endpoint.summary.connected && relayTasks[endpoint.id] == nil {
            let endpointID = endpoint.id
            relayTasks[endpointID] = Task { await self.runRelay(endpointID: endpointID) }
        }
    }

    private func runRelay(endpointID: String) async {
        let delays = [1, 2, 4, 8, 16, 32, 60]
        var delayIndex = 0
        while !Task.isCancelled {
            guard let endpoint = endpointsByID[endpointID] else { return }
            do {
                let api = try client(for: endpoint)
                let stream = await api.events(directory: nil)
                for try await event in stream {
                    try Task.checkCancellation()
                    guard isRecognized(event) else { continue }
                    try await relayReconciliation()
                }
            } catch is CancellationError {
                return
            } catch {
                // Reconnect below after marking only this endpoint unhealthy.
            }
            if Task.isCancelled { return }
            await markEndpointDisconnected(endpointID)
            do {
                try await Task.sleep(for: .seconds(delays[min(delayIndex, delays.count - 1)]))
                delayIndex = min(delayIndex + 1, delays.count - 1)
                guard var retryEndpoint = endpointsByID[endpointID] else { return }
                let health = try await client(for: retryEndpoint).health()
                guard health.healthy else { continue }
                retryEndpoint.summary.connected = true
                retryEndpoint.summary.version = health.version
                retryEndpoint.summary.message = nil
                retryEndpoint.summary.lastSeenAt = now()
                endpointsByID[endpointID] = retryEndpoint
                await registry.upsert(retryEndpoint)
                try await relayReconciliation()
                delayIndex = 0
            } catch is CancellationError {
                return
            } catch {
                continue
            }
        }
    }

    private func relayReconciliation() async throws {
        let previousRequestIDs = authoritativeRequestIDs
        let snapshot = try await reconcile()
        let currentRequestIDs = Set(snapshot.requests.map(\.id))
        for id in previousRequestIDs.subtracting(currentRequestIDs) {
            eventContinuation.yield(.requestExpired(id: id))
            lastEmittedRequests.removeValue(forKey: id)
        }
        for request in snapshot.requests where lastEmittedRequests[request.id] != request {
            eventContinuation.yield(.requestUpserted(request))
            lastEmittedRequests[request.id] = request
        }
        for session in snapshot.sessions where lastEmittedSessions[session.id] != session {
            eventContinuation.yield(.sessionUpserted(session))
            lastEmittedSessions[session.id] = session
        }
        for node in snapshot.nodes where lastEmittedNodes[node.id] != node {
            eventContinuation.yield(.nodeUpserted(node))
            lastEmittedNodes[node.id] = node
        }
    }

    private func isRecognized(_ event: OpenCodeEvent) -> Bool {
        ["session.", "message.", "permission.", "question."].contains {
            event.type.hasPrefix($0)
        }
    }

    private func markEndpointDisconnected(_ id: String) async {
        guard var endpoint = endpointsByID[id] else { return }
        endpoint.summary.connected = false
        endpoint.summary.message = "unavailable"
        endpoint.summary.lastSeenAt = now()
        endpointsByID[id] = endpoint
        await registry.upsert(endpoint)
    }

    private func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }

    private nonisolated static func makeHTTPClient(
        _ endpoint: OpenCodeRuntimeEndpoint
    ) -> any OpenCodeAPI {
        let baseURL = URL(string: endpoint.summary.baseURL)!
        let authorization: OpenCodeAuthorization
        switch endpoint.credential {
        case .ephemeral(let username, let password):
            authorization = .basic(username: username, password: password)
        case .none, .keychain:
            authorization = .none
        }
        return OpenCodeHTTPClient(baseURL: baseURL, authorization: authorization)
    }
}
