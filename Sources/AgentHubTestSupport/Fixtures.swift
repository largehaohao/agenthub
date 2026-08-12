import Foundation
import AgentHubCore

private enum FixtureValues {
    static let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let secondSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let nodeID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    static let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    static let envelopeID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
    static let date = Date(timeIntervalSince1970: 1_700_000_000)
}

public extension ProviderSessionRef {
    static func fixture(
        provider: Provider = .codex,
        accountID: String = "personal",
        nativeID: String = "codex-1"
    ) -> ProviderSessionRef {
        ProviderSessionRef(
            provider: provider,
            accountID: accountID,
            nativeID: nativeID
        )
    }
}

public extension VisibleTurn {
    static func fixture(
        id: String = "turn-1",
        role: String = "assistant",
        text: String = "Ready"
    ) -> VisibleTurn {
        VisibleTurn(id: id, role: role, text: text, createdAt: FixtureValues.date)
    }
}

public extension AgentSession {
    static func fixture(
        id: UUID? = nil,
        nativeID: String = "codex-1",
        status: SessionStatus = .idle,
        title: String = "Managed Codex session"
    ) -> AgentSession {
        let resolvedID = id ?? FixtureValues.sessionID
        return AgentSession(
            id: resolvedID,
            providerRef: .fixture(nativeID: nativeID),
            title: title,
            surface: "AgentHub",
            ownership: .managed,
            status: status,
            rootID: resolvedID,
            cwd: "/tmp/agenthub-fixture",
            repository: "agenthub",
            branch: "main",
            lastActivityAt: FixtureValues.date,
            capabilities: [
                .discover: .l1,
                .launch: .l1,
                .status: .l1,
                .children: .l1,
                .recentTurns: .l1,
                .sendInput: .l1,
                .resolveRequest: .l1,
                .jump: .l1,
                .quota: .l1,
            ],
            preview: [.fixture()]
        )
    }

    static var duplicateA: AgentSession {
        .fixture(title: "Older duplicate")
    }

    static var duplicateB: AgentSession {
        .fixture(id: FixtureValues.secondSessionID, title: "Newer duplicate")
    }
}

public extension AgentNode {
    static func fixture(
        status: SessionStatus = .working,
        parentNativeID: String? = "codex-1"
    ) -> AgentNode {
        AgentNode(
            id: FixtureValues.nodeID,
            sessionID: FixtureValues.sessionID,
            nativeID: "codex-child-1",
            parentNativeID: parentNativeID,
            kind: "subagent",
            status: status,
            lastActivityAt: FixtureValues.date
        )
    }
}

public extension PendingRequest {
    static func fixture(
        state: RequestState = .pending,
        provider: Provider = .codex
    ) -> PendingRequest {
        PendingRequest(
            id: FixtureValues.requestID,
            provider: provider,
            providerRequestID: "approval-1",
            sessionID: FixtureValues.sessionID,
            threadID: "codex-1",
            turnID: "turn-1",
            itemID: "item-1",
            kind: .permission,
            title: "Allow command?",
            detail: "Run tests",
            allowedActions: ["accept", "decline"],
            state: state,
            reliability: .l1,
            createdAt: FixtureValues.date,
            expiresAt: FixtureValues.date.addingTimeInterval(300)
        )
    }
}

public extension MessageEnvelope {
    static func fixture(state: DeliveryState = .queued) -> MessageEnvelope {
        MessageEnvelope(
            id: FixtureValues.envelopeID,
            sourceSessionID: FixtureValues.sessionID,
            targetSessionID: FixtureValues.secondSessionID,
            repository: "agenthub",
            cwd: "/tmp/agenthub-fixture",
            branch: "main",
            turns: [.fixture()],
            userNote: "Continue from this result",
            createdAt: FixtureValues.date,
            expiresAt: FixtureValues.date.addingTimeInterval(300),
            state: state
        )
    }
}

public extension QuotaWindow {
    static func fixture(usedPercent: Double = 25) -> QuotaWindow {
        try! QuotaWindow(
            provider: .codex,
            accountID: "personal",
            usedPercent: usedPercent,
            windowDuration: 18_000,
            resetsAt: FixtureValues.date.addingTimeInterval(9_000),
            fetchedAt: FixtureValues.date,
            source: "codex-app-server"
        )
    }
}

public extension LaunchRequest {
    static func fixture(clientRequestID: String = "launch-1") -> LaunchRequest {
        LaunchRequest(
            clientRequestID: clientRequestID,
            cwd: "/tmp/agenthub-fixture",
            prompt: "Inspect the project"
        )
    }
}

public extension AdapterSnapshot {
    static func fixture() -> AdapterSnapshot {
        AdapterSnapshot(
            sessions: [.fixture()],
            nodes: [.fixture()],
            requests: [.fixture()],
            quotas: [.fixture()]
        )
    }
}

public extension AgentInput {
    static func fixture() -> AgentInput {
        AgentInput(text: "Continue", provenance: "AgentHub fixture")
    }
}

public extension ProviderRequestRef {
    static func fixture() -> ProviderRequestRef {
        ProviderRequestRef(
            provider: .codex,
            requestID: "approval-1",
            threadID: "codex-1",
            turnID: "turn-1",
            itemID: "item-1"
        )
    }
}

public extension AdapterHealth {
    static func fixture(connected: Bool = true) -> AdapterHealth {
        AdapterHealth(connected: connected, changedAt: FixtureValues.date)
    }
}
