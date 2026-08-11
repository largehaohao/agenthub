import Foundation
import AgentHubCore

public actor CodexAdapter: AgentAdapter {
    public nonisolated let provider: Provider = .codex

    private let accountID: String
    private let rpc: CodexRPCClient
    private let now: @Sendable () -> Date
    private let events: AsyncStream<AgentEvent>
    private let eventContinuation: AsyncStream<AgentEvent>.Continuation
    private var sessionsByNativeID: [String: AgentSession] = [:]
    private var nodesByNativeID: [String: AgentNode] = [:]
    private var rootSessionIDByNativeID: [String: UUID] = [:]
    private var eventRelayStarted = false

    public init(
        accountID: String,
        rpc: CodexRPCClient,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.accountID = accountID
        self.rpc = rpc
        self.now = now
        let pair = AsyncStream<AgentEvent>.makeStream()
        events = pair.stream
        eventContinuation = pair.continuation
    }

    public func capabilities() async -> [Capability: ReliabilityLevel] {
        Dictionary(uniqueKeysWithValues: Capability.allCasesForAdapter.map { ($0, .l1) })
    }

    public func launch(_ request: LaunchRequest) async throws -> ProviderSessionRef {
        let result = try await rpc.call(
            method: "thread/start",
            params: .object(["cwd": .string(request.cwd)])
        )
        guard let nativeID = result["thread"]?["id"]?.stringValue else {
            throw CodexAdapterError.malformedResponse("thread/start")
        }
        let reference = ProviderSessionRef(
            provider: .codex,
            accountID: accountID,
            nativeID: nativeID
        )
        try await send(AgentInput(text: request.prompt, provenance: "AgentHub launch"), to: reference)
        return reference
    }

    public func reconcile() async throws -> AdapterSnapshot {
        let result = try await rpc.call(
            method: "thread/list",
            params: .object([
                "limit": .number(100),
                "sortKey": .string("recency_at"),
                "sortDirection": .string("desc"),
            ])
        )
        let threads = try result["data"]?.arrayValue?.map(CodexThread.init) ?? []
        let roots = threads.filter { $0.parentThreadID == nil }
        var sessions: [AgentSession] = []
        var rootIDsByThread: [String: UUID] = [:]

        for thread in roots {
            let id = stableCodexUUID(thread.id)
            rootIDsByThread[thread.id] = id
            let session = makeSession(thread, id: id)
            sessions.append(session)
            sessionsByNativeID[thread.id] = session
        }

        let threadByID = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
        let nodes = threads.compactMap { thread -> AgentNode? in
            guard let parent = thread.parentThreadID else { return nil }
            var rootNativeID = parent
            var visited: Set<String> = [thread.id]
            while let ancestor = threadByID[rootNativeID]?.parentThreadID,
                  visited.insert(rootNativeID).inserted {
                rootNativeID = ancestor
            }
            let rootID = rootIDsByThread[rootNativeID]
                ?? sessionsByNativeID[rootNativeID]?.id
                ?? stableCodexUUID(rootNativeID)
            let node = AgentNode(
                id: stableCodexUUID(thread.id),
                sessionID: rootID,
                nativeID: thread.id,
                parentNativeID: parent,
                kind: "subagent",
                status: thread.status,
                lastActivityAt: thread.updatedAt
            )
            nodesByNativeID[thread.id] = node
            rootSessionIDByNativeID[thread.id] = rootID
            return node
        }
        for session in sessions {
            rootSessionIDByNativeID[session.providerRef.nativeID] = session.id
        }
        let quotas = (try? await quotaWindows()) ?? []
        return AdapterSnapshot(sessions: sessions, nodes: nodes, requests: [], quotas: quotas)
    }

    public func eventStream() async -> AsyncStream<AgentEvent> {
        startEventRelayIfNeeded()
        return events
    }

    public func recentTurns(
        for session: ProviderSessionRef,
        limit: Int
    ) async throws -> [VisibleTurn] {
        let cappedLimit = max(0, min(limit, 20))
        let result = try await rpc.call(
            method: "thread/turns/list",
            params: .object([
                "threadId": .string(session.nativeID),
                "limit": .number(Double(cappedLimit)),
                "itemsView": .string("summary"),
                "sortDirection": .string("desc"),
            ])
        )
        return result["data"]?.arrayValue?.prefix(cappedLimit).compactMap(makeVisibleTurn) ?? []
    }

    public func send(_ input: AgentInput, to session: ProviderSessionRef) async throws {
        _ = try await rpc.call(
            method: "turn/start",
            params: .object([
                "threadId": .string(session.nativeID),
                "input": .array([.object([
                    "type": .string("text"),
                    "text": .string(input.text),
                ])]),
            ])
        )
    }

    public func resolve(
        _ request: ProviderRequestRef,
        decision: RequestDecision
    ) async throws {
        let result: JSONValue
        switch decision {
        case .accept: result = .object(["decision": .string("accept")])
        case .acceptForSession: result = .object(["decision": .string("acceptForSession")])
        case .decline: result = .object(["decision": .string("decline")])
        case .cancel: result = .object(["decision": .string("cancel")])
        case .text(let text): result = .object(["text": .string(text)])
        case .choices(let choices): result = .object(["choices": .array(choices.map(JSONValue.string))])
        case .answers: throw AdapterOperationError.unsupportedDecision
        }
        try await rpc.respond(id: .string(request.requestID), result: result)
    }

    public func jumpTarget(for session: ProviderSessionRef) async -> JumpTarget {
        .agentHubDetail(sessionNativeID: session.nativeID)
    }

    public func quotaWindows() async throws -> [QuotaWindow] {
        let result = try await rpc.call(
            method: "account/rateLimits/read",
            params: nil,
            timeout: .seconds(3)
        )
        guard let snapshot = result["rateLimits"] else { return [] }
        return try [snapshot["primary"], snapshot["secondary"]]
            .compactMap { $0 }
            .compactMap(makeQuotaWindow)
    }

    private func makeSession(_ thread: CodexThread, id: UUID) -> AgentSession {
        let preview: [VisibleTurn] = thread.preview.isEmpty ? [] : [VisibleTurn(
            id: "\(thread.id):preview",
            role: "user",
            text: thread.preview,
            createdAt: thread.updatedAt
        )]
        return AgentSession(
            id: id,
            providerRef: ProviderSessionRef(
                provider: .codex,
                accountID: accountID,
                nativeID: thread.id
            ),
            title: thread.name ?? (thread.preview.isEmpty ? thread.id : thread.preview.prefix(80).description),
            surface: "Codex app-server",
            ownership: .managed,
            status: thread.status,
            rootID: id,
            cwd: thread.cwd,
            branch: thread.branch,
            lastActivityAt: thread.updatedAt,
            capabilities: Dictionary(
                uniqueKeysWithValues: Capability.allCasesForAdapter.map { ($0, .l1) }
            ),
            preview: preview
        )
    }

    private func makeVisibleTurn(_ value: JSONValue) -> VisibleTurn? {
        guard let id = value["id"]?.stringValue else { return nil }
        let text = value["preview"]?.stringValue
            ?? value["summary"]?.stringValue
            ?? value["items"]?.arrayValue?.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
            ?? ""
        let created = value["createdAt"]?.numberValue.map(Date.init(timeIntervalSince1970:))
            ?? now()
        return VisibleTurn(id: id, role: "assistant", text: text, createdAt: created)
    }

    private func makeQuotaWindow(_ value: JSONValue) throws -> QuotaWindow? {
        guard let used = value["usedPercent"]?.numberValue,
              let durationMinutes = value["windowDurationMins"]?.numberValue,
              let reset = value["resetsAt"]?.numberValue else { return nil }
        return try QuotaWindow(
            provider: .codex,
            accountID: accountID,
            usedPercent: used,
            windowDuration: durationMinutes * 60,
            resetsAt: Date(timeIntervalSince1970: reset),
            fetchedAt: now(),
            source: "codex-app-server"
        )
    }

    private func startEventRelayIfNeeded() {
        guard !eventRelayStarted else { return }
        eventRelayStarted = true
        Task {
            let messages = await rpc.messages()
            for await message in messages {
                self.consume(message)
            }
        }
    }

    private func consume(_ message: JSONRPCMessage) {
        guard let method = message.method else { return }
        if message.isServerRequest,
           let requestID = message.id,
           let threadID = message.params?["threadId"]?.stringValue {
            let nativeRequestID: String
            switch requestID {
            case .string(let value): nativeRequestID = value
            case .integer(let value): nativeRequestID = String(value)
            }
            let request = PendingRequest(
                id: stableCodexUUID("request:\(nativeRequestID)"),
                provider: .codex,
                providerRequestID: nativeRequestID,
                sessionID: rootSessionIDByNativeID[threadID] ?? stableCodexUUID(threadID),
                threadID: threadID,
                turnID: message.params?["turnId"]?.stringValue,
                itemID: message.params?["itemId"]?.stringValue,
                kind: method.contains("requestApproval") ? .permission : .textInput,
                title: method.contains("requestApproval") ? "Codex permission request" : "Codex input request",
                detail: message.params?["reason"]?.stringValue ?? method,
                allowedActions: ["accept", "acceptForSession", "decline", "cancel"],
                state: .pending,
                reliability: .l1,
                createdAt: now()
            )
            eventContinuation.yield(.requestUpserted(request))
        } else if method == "thread/status/changed",
                  let threadID = message.params?["threadId"]?.stringValue {
            let status = CodexThread.mapStatus(message.params?["status"])
            if var session = sessionsByNativeID[threadID] {
                session.status = status
                session.lastActivityAt = now()
                sessionsByNativeID[threadID] = session
                eventContinuation.yield(.sessionUpserted(session))
            } else if var node = nodesByNativeID[threadID] {
                node.status = status
                node.lastActivityAt = now()
                nodesByNativeID[threadID] = node
                eventContinuation.yield(.nodeUpserted(node))
            }
        }
    }
}

private extension Capability {
    static let allCasesForAdapter: [Capability] = [
        .discover, .launch, .status, .children, .recentTurns,
        .sendInput, .resolveRequest, .jump, .quota,
    ]
}
