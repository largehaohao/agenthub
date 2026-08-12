import Foundation
import GRDB
import AgentHubCore

public actor AgentHubStore {
    private let database: DatabaseQueue

    public init(databaseURL: URL) throws {
        database = try AgentHubDatabase.open(at: databaseURL)
    }

    public func apply(_ event: AgentEvent) throws {
        switch event {
        case .sessionUpserted(let session):
            try persist(session)
        case .nodeUpserted(let node):
            try upsert(
                table: "agent_nodes",
                id: node.id.uuidString,
                body: node,
                extraColumns: ["session_id": node.sessionID.uuidString]
            )
        case .requestUpserted(let request):
            try persist(request)
        case .requestResolutionStarted(let id):
            try updateRequest(id: id, resolved: false)
        case .requestResolved(let id, _):
            try updateRequest(id: id, resolved: true)
        case .requestExpired(let id):
            try expireRequest(id: id)
        case .envelopeUpserted(let envelope):
            try upsert(table: "message_envelopes", id: envelope.id.uuidString, body: envelope)
        case .quotaUpserted(let quota):
            try upsert(table: "quota_windows", id: quota.id, body: quota)
        case .quotaRemoved(let id):
            try database.write { database in
                try database.execute(
                    sql: "DELETE FROM quota_windows WHERE id = ?",
                    arguments: [id]
                )
            }
        case .adapterHealth(let provider, let health):
            let body = try JSONEncoder.agentHub.encode(health)
            try database.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO adapter_health (provider, body) VALUES (?, ?)
                        ON CONFLICT(provider) DO UPDATE SET body = excluded.body
                        """,
                    arguments: [provider.rawValue, body]
                )
            }
        case .endpointUpserted(let endpoint):
            guard shouldPersist(endpoint) else { return }
            try upsert(
                table: "provider_endpoints",
                id: endpoint.id,
                body: endpoint,
                extraColumns: [
                    "provider": endpoint.provider.rawValue,
                    "origin": endpoint.origin.rawValue,
                ]
            )
        case .endpointRemoved(let id):
            try database.write { database in
                try database.execute(
                    sql: "DELETE FROM provider_endpoints WHERE id = ?",
                    arguments: [id]
                )
            }
        case .componentUpserted(let component):
            try upsert(
                table: "provider_components",
                id: component.id,
                body: component,
                extraColumns: [
                    "provider": component.provider.rawValue,
                    "component": component.component,
                ]
            )
        }
    }

    public func snapshot() throws -> AgentHubState {
        try database.read { database in
            var state = AgentHubState.empty

            for row in try Row.fetchAll(database, sql: "SELECT id, body FROM sessions") {
                var session: AgentSession = try decode(row["body"])
                session.preview = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT body FROM cached_turns
                        WHERE session_id = ? ORDER BY position ASC
                        """,
                    arguments: [session.id.uuidString]
                ).map { try decode($0["body"]) }
                state.sessions[session.id] = session
            }

            for row in try Row.fetchAll(database, sql: "SELECT body FROM agent_nodes") {
                let value: AgentNode = try decode(row["body"])
                state.nodes[value.id] = value
            }
            for row in try Row.fetchAll(database, sql: "SELECT body FROM pending_requests") {
                let value: PendingRequest = try decode(row["body"])
                state.requests[value.id] = value
            }
            for row in try Row.fetchAll(database, sql: "SELECT body FROM message_envelopes") {
                let value: MessageEnvelope = try decode(row["body"])
                state.envelopes[value.id] = value
            }
            for row in try Row.fetchAll(database, sql: "SELECT body FROM quota_windows") {
                let value: QuotaWindow = try decode(row["body"])
                state.quotas[value.id] = value
            }
            for row in try Row.fetchAll(database, sql: "SELECT provider, body FROM adapter_health") {
                guard let provider = Provider(rawValue: row["provider"]) else { continue }
                let value: AdapterHealth = try decode(row["body"])
                state.adapterHealth[provider] = value
            }
            for row in try Row.fetchAll(database, sql: "SELECT body FROM provider_endpoints") {
                let value: ProviderEndpoint = try decode(row["body"])
                state.endpoints[value.id] = value
            }
            for row in try Row.fetchAll(database, sql: "SELECT body FROM provider_components") {
                let value: ProviderComponentStatus = try decode(row["body"])
                state.components[value.id] = value
            }
            return state
        }
    }

    public func prunePreviewCache(now: Date) throws {
        let cutoff = now.addingTimeInterval(-PreviewCachePolicy.retention).timeIntervalSince1970
        try database.write { database in
            try database.execute(
                sql: """
                    DELETE FROM cached_turns
                    WHERE session_id IN (
                        SELECT id FROM sessions
                        WHERE status = ? AND last_activity_at <= ?
                    )
                    """,
                arguments: [SessionStatus.completed.rawValue, cutoff]
            )
        }
    }

    public func appendAudit(_ event: AuditEvent) throws {
        try upsert(table: "audit_events", id: event.id.uuidString, body: event,
                   extraColumns: ["created_at": event.createdAt.timeIntervalSince1970])
    }

    private func persist(_ session: AgentSession) throws {
        let turns = try retainedPreview(from: session.preview)
        var storedSession = session
        storedSession.preview = []
        let body = try JSONEncoder.agentHub.encode(storedSession)

        try database.write { database in
            if let oldID = try String.fetchOne(
                database,
                sql: """
                    SELECT id FROM sessions
                    WHERE provider = ? AND account_id = ? AND native_id = ?
                    """,
                arguments: [
                    session.providerRef.provider.rawValue,
                    session.providerRef.accountID,
                    session.providerRef.nativeID,
                ]
            ), oldID != session.id.uuidString {
                try database.execute(
                    sql: "DELETE FROM cached_turns WHERE session_id = ?",
                    arguments: [oldID]
                )
            }

            try database.execute(
                sql: """
                    INSERT INTO sessions
                        (id, provider, account_id, native_id, status, last_activity_at, body)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(provider, account_id, native_id) DO UPDATE SET
                        id = excluded.id,
                        status = excluded.status,
                        last_activity_at = excluded.last_activity_at,
                        body = excluded.body
                    """,
                arguments: [
                    session.id.uuidString,
                    session.providerRef.provider.rawValue,
                    session.providerRef.accountID,
                    session.providerRef.nativeID,
                    session.status.rawValue,
                    session.lastActivityAt.timeIntervalSince1970,
                    body,
                ]
            )
            try database.execute(
                sql: "DELETE FROM cached_turns WHERE session_id = ?",
                arguments: [session.id.uuidString]
            )
            for (position, turn) in turns.enumerated() {
                let turnBody = try JSONEncoder.agentHub.encode(turn)
                try database.execute(
                    sql: """
                        INSERT INTO cached_turns
                            (session_id, turn_id, position, byte_count, body)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        session.id.uuidString,
                        turn.id,
                        position,
                        turnBody.count,
                        turnBody,
                    ]
                )
            }
        }
    }

    private func persist(_ request: PendingRequest) throws {
        try database.write { database in
            let existingBody = try Data.fetchOne(
                database,
                sql: """
                    SELECT body FROM pending_requests
                    WHERE provider = ? AND provider_request_id = ?
                    """,
                arguments: [request.provider.rawValue, request.providerRequestID]
            )
            let storedRequest: PendingRequest
            if let existingBody {
                let existing: PendingRequest = try decode(existingBody)
                storedRequest = mergedRequest(existing: existing, incoming: request)
            } else {
                storedRequest = request
            }
            let body = try JSONEncoder.agentHub.encode(storedRequest)
            try database.execute(
                sql: """
                    INSERT INTO pending_requests
                        (id, provider, provider_request_id, body)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(provider, provider_request_id) DO UPDATE SET
                        id = excluded.id,
                        body = excluded.body
                    """,
                arguments: [
                    storedRequest.id.uuidString,
                    storedRequest.provider.rawValue,
                    storedRequest.providerRequestID,
                    body,
                ]
            )
        }
    }

    private func updateRequest(id: UUID, resolved: Bool) throws {
        try database.write { database in
            guard let body = try Data.fetchOne(
                database,
                sql: "SELECT body FROM pending_requests WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return }

            var request: PendingRequest = try decode(body)
            var state = AgentHubState(requests: [id: request])
            if resolved {
                StateReducer.reduce(state: &state, event: .requestResolved(id: id, outcome: "stored"))
            } else {
                StateReducer.reduce(state: &state, event: .requestResolutionStarted(id: id))
            }
            guard let updated = state.requests[id], updated != request else { return }
            request = updated
            let updatedBody = try JSONEncoder.agentHub.encode(request)
            try database.execute(
                sql: "UPDATE pending_requests SET body = ? WHERE id = ?",
                arguments: [updatedBody, id.uuidString]
            )
        }
    }

    private func expireRequest(id: UUID) throws {
        try database.write { database in
            guard let body = try Data.fetchOne(
                database,
                sql: "SELECT body FROM pending_requests WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return }
            let request: PendingRequest = try decode(body)
            var state = AgentHubState(requests: [id: request])
            StateReducer.reduce(state: &state, event: .requestExpired(id: id))
            guard let updated = state.requests[id], updated != request else { return }
            try database.execute(
                sql: "UPDATE pending_requests SET body = ? WHERE id = ?",
                arguments: [try JSONEncoder.agentHub.encode(updated), id.uuidString]
            )
        }
    }

    private func upsert<Value: Encodable>(
        table: String,
        id: String,
        body value: Value,
        extraColumns: [String: (any DatabaseValueConvertible)?] = [:]
    ) throws {
        let body = try JSONEncoder.agentHub.encode(value)
        let columns = ["id", "body"] + extraColumns.keys.sorted()
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        let updates = columns.dropFirst().map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
        var arguments: [DatabaseValueConvertible?] = [id, body]
        arguments.append(contentsOf: extraColumns.keys.sorted().map { extraColumns[$0] ?? nil })

        try database.write { database in
            try database.execute(
                sql: """
                    INSERT INTO \(table) (\(columns.joined(separator: ", ")))
                    VALUES (\(placeholders))
                    ON CONFLICT(id) DO UPDATE SET \(updates)
                    """,
                arguments: StatementArguments(arguments)
            )
        }
    }

    private func retainedPreview(from preview: [VisibleTurn]) throws -> [VisibleTurn] {
        var retained: [VisibleTurn] = []
        var byteCount = 0
        for turn in preview.suffix(PreviewCachePolicy.maximumTurns).reversed() {
            let size = try JSONEncoder.agentHub.encode(turn).count
            guard byteCount + size <= PreviewCachePolicy.maximumBytes else { continue }
            retained.append(turn)
            byteCount += size
        }
        return retained.reversed()
    }

    private func shouldPersist(_ endpoint: ProviderEndpoint) -> Bool {
        if endpoint.origin == .manual { return true }
        return endpoint.credentialReference != nil
            && (endpoint.origin == .desktop || endpoint.origin == .tui)
    }
}

private func decode<Value: Decodable>(_ data: Data) throws -> Value {
    try JSONDecoder.agentHub.decode(Value.self, from: data)
}

private func mergedRequest(
    existing: PendingRequest,
    incoming: PendingRequest
) -> PendingRequest {
    if existing.state == .resolved || existing.state == .expired {
        return existing
    }
    return requestRank(incoming.state) >= requestRank(existing.state) ? incoming : existing
}

private func requestRank(_ state: RequestState) -> Int {
    switch state {
    case .pending: 0
    case .resolving: 1
    case .resolved, .expired: 2
    }
}
