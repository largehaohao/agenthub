import XCTest
@testable import AgentHubQuota

/// Guards the one provider that shells out.
///
/// Codex is reached by spawning `codex app-server`, so unlike the other three it
/// depends on the environment it is given. A Finder launch inherits launchd's,
/// which is nearly empty, and that has broken Codex twice for different reasons:
///
///  - `PATH` held neither `codex` nor the `node` its shebang needs, so the
///    process would not start.
///  - No proxy variables, so `codex` started but could not reach the network and
///    the call timed out. `URLSession` reads the system PAC file and the other
///    three providers were unaffected, which made it look Codex-specific.
///
/// Both were invisible from a terminal, where the user's shell supplies all of
/// it. The environment here is deliberately barer than a real Finder launch.
///
/// Run with:
/// ```
/// AGENTHUB_LIVE_QUOTA=1 swift test --filter CodexGuiLaunchProbeTests
/// ```
final class CodexGuiLaunchProbeTests: XCTestCase {
    func testCodexIsReachableFromAFinderLaunch() async throws {
        guard ProcessInfo.processInfo.environment["AGENTHUB_LIVE_QUOTA"] == "1" else {
            throw XCTSkip("set AGENTHUB_LIVE_QUOTA=1 to run against real providers")
        }

        let finderLaunch = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
        ]
        let rpc = CodexRPCClient(transport: CodexProcess(environment: finderLaunch))
        defer { Task { await rpc.stop() } }

        try await rpc.start(clientName: "AgentHub", clientVersion: "1")
        let result = try await rpc.call(
            method: "account/rateLimits/read",
            params: nil,
            timeout: .seconds(15)
        )
        let windows = try CodexQuotaDecoder(accountID: "default")
            .decode(JSONEncoder().encode(result), now: Date())

        print("  codex under a Finder launch: \(windows.map { "\($0.canonicalLabel) \(Int($0.usedPercent))%" })")
        XCTAssertFalse(windows.isEmpty)
    }
}
