import Foundation
import AgentHubCore

/// Releases queued handoffs when a target session becomes idle.
///
/// Delivery is driven by the *transition* from busy to idle rather than by the
/// idle state itself. Repeated snapshots of an already-idle session therefore
/// never redeliver an envelope, which is what keeps a handoff from being pasted
/// into a session more than once.
public actor DeliveryReconciler {
    private let handoffs: HandoffService
    private var lastStatus: [UUID: SessionStatus] = [:]

    public init(handoffs: HandoffService) {
        self.handoffs = handoffs
    }

    /// Consumes a coordinator snapshot and releases at most one queued batch per
    /// session that just became idle.
    public func reconcile(_ state: AgentHubState) async {
        for session in state.sessions.values {
            let previous = lastStatus[session.id]
            lastStatus[session.id] = session.status

            // Only a genuine transition into idle is a delivery signal. An
            // unknown previous status (first observation) is not a transition.
            guard session.status == .idle,
                  let previous,
                  previous != .idle else { continue }

            let pending = state.requests.values.filter { $0.sessionID == session.id }
            await handoffs.sessionBecameIdle(session, pendingRequests: pending)
        }
    }
}
