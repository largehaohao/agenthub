import Foundation

public enum SessionTreeRowValue: Equatable, Sendable {
    case session(AgentSession)
    case node(AgentNode)
}

public struct SessionTreeRow: Equatable, Identifiable, Sendable {
    public let id: String
    public let value: SessionTreeRowValue
    public var children: [SessionTreeRow]

    public init(
        id: String,
        value: SessionTreeRowValue,
        children: [SessionTreeRow] = []
    ) {
        self.id = id
        self.value = value
        self.children = children
    }
}

public enum SessionTreeBuilder {
    public static func build(
        sessions: [AgentSession],
        nodes: [AgentNode]
    ) -> [SessionTreeRow] {
        let canonicalSessions = deduplicatedSessions(sessions)
        let identityBySessionID = sessionIdentityMap(
            sessions: sessions,
            canonical: canonicalSessions
        )
        let groupedNodes = Dictionary(grouping: nodes) { node in
            identityBySessionID[node.sessionID] ?? "orphan:\(node.sessionID.uuidString)"
        }

        var rows = canonicalSessions.map { identity, session in
            let sessionNodes = deduplicatedNodes(groupedNodes[identity] ?? [])
            let children = nodeForest(
                nodes: sessionNodes,
                explicitSessionParent: session.providerRef.nativeID,
                identity: identity
            )
            return SessionTreeRow(
                id: "session:\(identity)",
                value: .session(session),
                children: children.attached
            )
        }

        let canonicalIdentities = Set(canonicalSessions.keys)
        for (identity, group) in groupedNodes where !canonicalIdentities.contains(identity) {
            let forest = nodeForest(
                nodes: deduplicatedNodes(group),
                explicitSessionParent: nil,
                identity: identity
            )
            rows.append(contentsOf: forest.attached)
            rows.append(contentsOf: forest.roots)
        }

        for (identity, group) in groupedNodes where canonicalIdentities.contains(identity) {
            let sessionNativeID = canonicalSessions[identity]?.providerRef.nativeID
            let forest = nodeForest(
                nodes: deduplicatedNodes(group),
                explicitSessionParent: sessionNativeID,
                identity: identity
            )
            rows.append(contentsOf: forest.roots)
        }

        return rows.sorted(by: rowSort)
    }

    private static func deduplicatedSessions(
        _ sessions: [AgentSession]
    ) -> [String: AgentSession] {
        sessions.reduce(into: [:]) { result, session in
            let identity = identity(for: session.providerRef)
            guard let current = result[identity] else {
                result[identity] = session
                return
            }
            if session.lastActivityAt > current.lastActivityAt
                || (session.lastActivityAt == current.lastActivityAt
                    && session.id.uuidString < current.id.uuidString)
            {
                result[identity] = session
            }
        }
    }

    private static func sessionIdentityMap(
        sessions: [AgentSession],
        canonical: [String: AgentSession]
    ) -> [UUID: String] {
        var result: [UUID: String] = [:]
        for session in sessions {
            let key = identity(for: session.providerRef)
            guard canonical[key] != nil else { continue }
            result[session.id] = key
        }
        return result
    }

    private static func deduplicatedNodes(_ nodes: [AgentNode]) -> [AgentNode] {
        Array(
            nodes.reduce(into: [String: AgentNode]()) { result, node in
                guard let current = result[node.nativeID] else {
                    result[node.nativeID] = node
                    return
                }
                if node.lastActivityAt > current.lastActivityAt
                    || (node.lastActivityAt == current.lastActivityAt
                        && node.id.uuidString < current.id.uuidString)
                {
                    result[node.nativeID] = node
                }
            }.values
        )
    }

    private static func nodeForest(
        nodes: [AgentNode],
        explicitSessionParent: String?,
        identity: String
    ) -> (attached: [SessionTreeRow], roots: [SessionTreeRow]) {
        let byNativeID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.nativeID, $0) })
        let childrenByParent = Dictionary(grouping: nodes.compactMap { node in
            node.parentNativeID.map { ($0, node) }
        }, by: \.0).mapValues { $0.map(\.1) }
        var represented = Set<String>()

        func row(for node: AgentNode, ancestry: Set<String>) -> SessionTreeRow {
            represented.insert(node.nativeID)
            let nextAncestry = ancestry.union([node.nativeID])
            let children = (childrenByParent[node.nativeID] ?? [])
                .filter { !nextAncestry.contains($0.nativeID) }
                .map { row(for: $0, ancestry: nextAncestry) }
                .sorted(by: rowSort)
            return SessionTreeRow(
                id: "node:\(identity):\(node.nativeID)",
                value: .node(node),
                children: children
            )
        }

        let attachedNodes: [AgentNode]
        if let explicitSessionParent {
            attachedNodes = childrenByParent[explicitSessionParent] ?? []
        } else {
            attachedNodes = []
        }
        let attached = attachedNodes
            .map { row(for: $0, ancestry: []) }
            .sorted(by: rowSort)

        let explicitRoots = nodes.filter { node in
            guard let parent = node.parentNativeID else { return true }
            return parent != explicitSessionParent && byNativeID[parent] == nil
        }
        var roots = explicitRoots
            .filter { !represented.contains($0.nativeID) }
            .map { row(for: $0, ancestry: []) }

        let cycleOrphans = nodes
            .filter { !represented.contains($0.nativeID) }
            .map { row(for: $0, ancestry: []) }
        roots.append(contentsOf: cycleOrphans)

        return (attached, roots.sorted(by: rowSort))
    }

    private static func identity(for reference: ProviderSessionRef) -> String {
        "\(reference.provider.rawValue):\(reference.accountID):\(reference.nativeID)"
    }

    private static func rowSort(_ lhs: SessionTreeRow, _ rhs: SessionTreeRow) -> Bool {
        rowDate(lhs) == rowDate(rhs)
            ? lhs.id < rhs.id
            : rowDate(lhs) > rowDate(rhs)
    }

    private static func rowDate(_ row: SessionTreeRow) -> Date {
        switch row.value {
        case .session(let session): session.lastActivityAt
        case .node(let node): node.lastActivityAt
        }
    }
}
