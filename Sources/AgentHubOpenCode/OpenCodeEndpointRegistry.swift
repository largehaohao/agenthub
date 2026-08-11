import Foundation
import AgentHubCore

enum OpenCodeCredential: Equatable, Sendable {
    case none
    case ephemeral(username: String, password: String)
    case keychain(username: String, reference: String)
}

struct OpenCodeRuntimeEndpoint: Equatable, Sendable {
    var summary: ProviderEndpoint
    let credential: OpenCodeCredential
    let processID: Int32?
    let applicationBundleID: String?
    let terminalTTY: String?

    var id: String { summary.id }
}

enum OpenCodeOperation: Sendable {
    case read
    case send
    case resolveRequest
    case jump
}

actor OpenCodeEndpointRegistry {
    private struct Observation: Sendable {
        let directory: String
        let observedAt: Date
    }

    private var endpointsByID: [String: OpenCodeRuntimeEndpoint] = [:]
    private var observationsBySession: [String: [String: Observation]] = [:]

    func upsert(_ endpoint: OpenCodeRuntimeEndpoint) {
        endpointsByID[endpoint.id] = endpoint
    }

    func remove(endpointID: String) {
        endpointsByID.removeValue(forKey: endpointID)
        for sessionID in observationsBySession.keys {
            observationsBySession[sessionID]?.removeValue(forKey: endpointID)
            if observationsBySession[sessionID]?.isEmpty == true {
                observationsBySession.removeValue(forKey: sessionID)
            }
        }
    }

    func observe(
        sessionID: String,
        directory: String,
        endpointID: String,
        at observedAt: Date
    ) {
        guard endpointsByID[endpointID] != nil else { return }
        observationsBySession[sessionID, default: [:]][endpointID] = Observation(
            directory: directory,
            observedAt: observedAt
        )
    }

    func surfaces(sessionID: String) -> [ProviderEndpointOrigin] {
        let observed = observationsBySession[sessionID] ?? [:]
        let values = observed.keys.compactMap { endpointID -> ProviderEndpointOrigin? in
            guard let endpoint = endpointsByID[endpointID], endpoint.summary.connected else {
                return nil
            }
            return endpoint.summary.origin
        }
        return Array(Set(values)).sorted { originRank($0) < originRank($1) }
    }

    func route(
        sessionID: String,
        directory: String,
        operation: OpenCodeOperation
    ) -> OpenCodeRuntimeEndpoint? {
        let observed = observationsBySession[sessionID] ?? [:]
        let candidates = observed.compactMap { endpointID, observation -> Candidate? in
            guard observation.directory == directory,
                  let endpoint = endpointsByID[endpointID],
                  endpoint.summary.connected else {
                return nil
            }
            return Candidate(endpoint: endpoint, observation: observation)
        }
        return candidates.sorted {
            let leftPriority = routePriority($0.endpoint.summary.origin, operation: operation)
            let rightPriority = routePriority($1.endpoint.summary.origin, operation: operation)
            if leftPriority != rightPriority { return leftPriority > rightPriority }
            if $0.observation.observedAt != $1.observation.observedAt {
                return $0.observation.observedAt > $1.observation.observedAt
            }
            return $0.endpoint.id < $1.endpoint.id
        }.first?.endpoint
    }

    private struct Candidate {
        let endpoint: OpenCodeRuntimeEndpoint
        let observation: Observation
    }

    private func routePriority(
        _ origin: ProviderEndpointOrigin,
        operation: OpenCodeOperation
    ) -> Int {
        switch operation {
        case .jump:
            switch origin {
            case .desktop, .tui: 3
            case .manual: 2
            case .managed: 1
            }
        case .read, .send, .resolveRequest:
            switch origin {
            case .managed: 3
            case .desktop, .tui: 2
            case .manual: 1
            }
        }
    }

    private func originRank(_ origin: ProviderEndpointOrigin) -> Int {
        switch origin {
        case .managed: 0
        case .desktop: 1
        case .tui: 2
        case .manual: 3
        }
    }
}

func stableOpenCodeUUID(accountID: String, nativeID: String) -> UUID {
    let value = "openCode\0\(accountID)\0\(nativeID)"
    var first: UInt64 = 0xcbf29ce484222325
    var second: UInt64 = 0x84222325cbf29ce4
    for byte in value.utf8 {
        first = (first ^ UInt64(byte)) &* 0x100000001b3
        second = (second ^ UInt64(byte)) &* 0x9e3779b185ebca87
    }
    var bytes = withUnsafeBytes(of: first.bigEndian, Array.init)
        + withUnsafeBytes(of: second.bigEndian, Array.init)
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}
