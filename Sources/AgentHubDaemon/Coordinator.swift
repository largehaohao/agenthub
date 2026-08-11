import Foundation
import AgentHubCore
import AgentHubPersistence

public enum CoordinatorError: Error, Equatable, Sendable {
    case notStarted
    case unsupportedProvider
    case sessionNotFound
}

public actor Coordinator {
    private let store: AgentHubStore
    private let adapters: [Provider: any AgentAdapter]
    private let changeStream: AsyncStream<UInt64>
    private let changeContinuation: AsyncStream<UInt64>.Continuation
    private var state: AgentHubState = .empty
    private var launchResults: [String: UUID] = [:]
    private var launchesInFlight: [String: Task<UUID, Error>] = [:]
    private var eventTasks: [Task<Void, Never>] = []
    private var sequence: UInt64 = 0
    private var started = false

    public init(
        store: AgentHubStore,
        adapters: [Provider: any AgentAdapter]
    ) {
        self.store = store
        self.adapters = adapters
        let pair = AsyncStream<UInt64>.makeStream()
        changeStream = pair.stream
        changeContinuation = pair.continuation
    }

    public init(
        store: AgentHubStore,
        adapters: [Provider: any AgentAdapter],
        clock: any Clock<Duration>
    ) {
        self.init(store: store, adapters: adapters)
        _ = clock
    }

    public func start() async throws {
        guard !started else { return }
        state = try await store.snapshot()

        for provider in adapters.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let adapter = adapters[provider] else { continue }
            do {
                let snapshot = try await adapter.reconcile()
                try await merge(snapshot, publish: false)
                try await persistAndReduce(
                    .adapterHealth(
                        provider,
                        AdapterHealth(connected: true, changedAt: Date())
                    ),
                    publish: false
                )
            } catch {
                try await persistAndReduce(
                    .adapterHealth(
                        provider,
                        AdapterHealth(
                            connected: false,
                            message: "Provider unavailable",
                            changedAt: Date()
                        )
                    ),
                    publish: false
                )
            }
        }

        sequence = 0
        started = true
        for adapter in adapters.values {
            let task = Task {
                let stream = await adapter.eventStream()
                for await event in stream {
                    try? await self.apply(event)
                }
            }
            eventTasks.append(task)
        }
    }

    public func stop() async {
        guard started else { return }
        started = false
        for task in eventTasks { task.cancel() }
        eventTasks.removeAll()
        for task in launchesInFlight.values { task.cancel() }
        launchesInFlight.removeAll()
        changeContinuation.finish()
    }

    public func snapshot() -> AgentHubState {
        state
    }

    public func changes() -> AsyncStream<UInt64> {
        changeStream
    }

    public func launch(provider: Provider, request: LaunchRequest) async throws -> UUID {
        guard started else { throw CoordinatorError.notStarted }
        if let existing = launchResults[request.clientRequestID] { return existing }
        if let inFlight = launchesInFlight[request.clientRequestID] {
            return try await inFlight.value
        }
        guard let adapter = adapters[provider] else {
            throw CoordinatorError.unsupportedProvider
        }

        let task = Task {
            try await self.performLaunch(adapter: adapter, request: request)
        }
        launchesInFlight[request.clientRequestID] = task
        do {
            let id = try await task.value
            launchResults[request.clientRequestID] = id
            launchesInFlight.removeValue(forKey: request.clientRequestID)
            return id
        } catch {
            launchesInFlight.removeValue(forKey: request.clientRequestID)
            throw error
        }
    }

    private func performLaunch(
        adapter: any AgentAdapter,
        request: LaunchRequest
    ) async throws -> UUID {
        let reference = try await adapter.launch(request)
        let reconciled = try await adapter.reconcile()
        try await merge(reconciled, publish: true)
        let id: UUID
        if let session = state.sessions.values.first(where: { $0.providerRef == reference }) {
            id = session.id
        } else {
            let capabilities = await adapter.capabilities()
            let generatedID = UUID(uuidString: reference.nativeID) ?? UUID()
            let session = AgentSession(
                id: generatedID,
                providerRef: reference,
                title: request.prompt.prefix(80).description,
                surface: "AgentHub",
                ownership: .managed,
                status: .starting,
                rootID: generatedID,
                cwd: request.cwd,
                lastActivityAt: Date(),
                capabilities: capabilities,
                preview: []
            )
            try await apply(.sessionUpserted(session))
            id = generatedID
        }
        return id
    }

    public func apply(_ event: AgentEvent) async throws {
        guard started else { throw CoordinatorError.notStarted }
        try await persistAndReduce(event, publish: true)
    }

    public func refreshFromStore() async throws {
        state = try await store.snapshot()
        publishChange()
    }

    public func send(_ input: AgentInput, to sessionID: UUID) async throws {
        guard let session = state.sessions[sessionID] else {
            throw CoordinatorError.sessionNotFound
        }
        guard let adapter = adapters[session.providerRef.provider] else {
            throw CoordinatorError.unsupportedProvider
        }
        try await adapter.send(input, to: session.providerRef)
    }

    public func jumpTarget(for sessionID: UUID) async throws -> JumpTarget {
        guard let session = state.sessions[sessionID] else {
            throw CoordinatorError.sessionNotFound
        }
        guard let adapter = adapters[session.providerRef.provider] else {
            throw CoordinatorError.unsupportedProvider
        }
        return await adapter.jumpTarget(for: session.providerRef)
    }

    private func merge(_ snapshot: AdapterSnapshot, publish: Bool) async throws {
        for session in snapshot.sessions {
            try await persistAndReduce(.sessionUpserted(session), publish: publish)
        }
        for node in snapshot.nodes {
            try await persistAndReduce(.nodeUpserted(node), publish: publish)
        }
        for request in snapshot.requests {
            try await persistAndReduce(.requestUpserted(request), publish: publish)
        }
        for quota in snapshot.quotas {
            try await persistAndReduce(.quotaUpserted(quota), publish: publish)
        }
    }

    private func persistAndReduce(_ event: AgentEvent, publish: Bool) async throws {
        try await store.apply(event)
        StateReducer.reduce(state: &state, event: event)
        if publish { publishChange() }
    }

    private func publishChange() {
        sequence &+= 1
        changeContinuation.yield(sequence)
    }
}
