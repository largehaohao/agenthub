import Foundation

/// Paces the quota refresh loop: a steady cadence while the source is healthy,
/// and a bounded backoff while it is not, so a broken or unauthenticated
/// CodexBar is never polled in a tight loop.
public struct ClaudeQuotaRefreshSchedule: Sendable {
    public static let successInterval: TimeInterval = 300
    public static let failureDelays: [TimeInterval] = [60, 120, 240, 480, 900]

    private var consecutiveFailures = 0

    public init() {}

    /// Returns the delay before the next attempt. One valid snapshot resets the
    /// backoff so recovery is immediate rather than gradual.
    public mutating func nextDelay(afterFailure failed: Bool) -> TimeInterval {
        guard failed else {
            consecutiveFailures = 0
            return Self.successInterval
        }

        let index = min(consecutiveFailures, Self.failureDelays.count - 1)
        consecutiveFailures += 1
        return Self.failureDelays[index]
    }
}
