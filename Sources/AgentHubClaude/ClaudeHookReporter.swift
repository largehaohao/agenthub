import Darwin
import Foundation
import AgentHubCore

/// Bridges one Claude hook invocation to the AgentHub daemon.
///
/// The reporter validates size and shape before sending, attaches bounded
/// current-user process ancestry, and never copies environment variables, so a
/// hook payload cannot carry credentials into the daemon.
public struct ClaudeHookReporter: Sendable {
    /// Ancestry is only used to classify the surface (managed CLI, external
    /// CLI, or Desktop); a shallow walk is enough and bounds the work done
    /// inside a hook that must not delay Claude.
    public static let maximumAncestors = 8

    private let ancestry: @Sendable (Int32) -> [ProcessObservation]
    private let send: @Sendable (ProviderHookEnvelope) async throws -> Void
    private let now: @Sendable () -> Date

    public init(
        ancestry: @escaping @Sendable (Int32) -> [ProcessObservation] = {
            ClaudeProcessAncestry.walk(from: $0, limit: ClaudeHookReporter.maximumAncestors)
        },
        send: @escaping @Sendable (ProviderHookEnvelope) async throws -> Void,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.ancestry = ancestry
        self.send = send
        self.now = now
    }

    public func report(stdin: Data, sourcePID: Int32) async throws {
        guard stdin.count <= ProviderHookEnvelope.maximumPayloadBytes else {
            throw ProviderHookEnvelopeError.oversizedPayload
        }

        // Validate shape before sending. An unsupported event name still
        // forwards as `.unknown`, but unparsable bytes never reach the daemon.
        _ = try ClaudeHookDecoder().decode(stdin)

        let envelope = try ProviderHookEnvelope(
            provider: .claude,
            rawJSON: stdin,
            sourcePID: sourcePID,
            ancestors: ancestry(sourcePID),
            observedAt: now()
        )
        try await send(envelope)
    }
}

/// Reads current-user process ancestry through `sysctl`, without shelling out.
public enum ClaudeProcessAncestry {
    public static func walk(from pid: Int32, limit: Int) -> [ProcessObservation] {
        var observations: [ProcessObservation] = []
        var current = pid
        let uid = getuid()

        while observations.count < limit, current > 1 {
            guard let info = processInfo(for: current), info.uid == uid else { break }
            observations.append(info)
            current = info.parentPID
        }
        return observations
    }

    private static func processInfo(for pid: Int32) -> ProcessObservation? {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride

        let result = sysctl(&name, UInt32(name.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }

        let command = withUnsafeBytes(of: info.kp_proc.p_comm) { buffer in
            String(cString: buffer.baseAddress!.assumingMemoryBound(to: CChar.self))
        }

        return ProcessObservation(
            pid: info.kp_proc.p_pid,
            parentPID: info.kp_eproc.e_ppid,
            uid: info.kp_eproc.e_ucred.cr_uid,
            tty: nil,
            command: command
        )
    }
}
