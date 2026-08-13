import XCTest
@testable import AgentHubQuota

/// Exercises the real providers. Opt-in, because it makes network calls, reads
/// local credentials, and starts a `codex app-server` subprocess.
///
/// Run with:
/// ```
/// AGENTHUB_LIVE_QUOTA=1 swift test --filter LiveQuotaTests
/// ```
final class LiveQuotaTests: XCTestCase {
    private func requireOptIn() throws {
        guard ProcessInfo.processInfo.environment["AGENTHUB_LIVE_QUOTA"] == "1" else {
            throw XCTSkip("set AGENTHUB_LIVE_QUOTA=1 to run against real providers")
        }
    }

    func testEveryProviderReportsSomething() async throws {
        try requireOptIn()

        let windows = await QuotaService.live().windows(force: true)
        let byProvider = Dictionary(grouping: windows, by: \.provider)

        for provider in Provider.allCases {
            let rows = byProvider[provider] ?? []
            let summary = rows
                .sorted { $0.windowDuration < $1.windowDuration }
                .map { "\($0.canonicalLabel) \(Int($0.usedPercent.rounded()))%" }
                .joined(separator: "  ")
            print("  \(provider.displayName): \(rows.isEmpty ? "none" : summary)")
        }

        // Two providers are conditional and must not fail this test:
        //
        //  - Claude needs the login Keychain, and reading another app's item
        //    raises an approval dialog the first time. A non-interactive test
        //    process cannot show one, so it gets errSecInteractionNotAllowed.
        //  - Cursor stays silent until it is authorised in Settings.
        //
        // OpenCode and Codex read a file and a subprocess, so they should
        // always report.
        XCTAssertFalse(
            (byProvider[.openCode] ?? []).isEmpty,
            "OpenCode usage should be readable from the CLI's auth.json"
        )
        if (byProvider[.claude] ?? []).isEmpty {
            print("  (Claude absent: the Keychain item needs interactive approval)")
        }
    }

    /// The percentages must be usable numbers, not placeholders.
    func testReportedWindowsAreWellFormed() async throws {
        try requireOptIn()

        let windows = await QuotaService.live().windows(force: true)

        XCTAssertFalse(windows.isEmpty)
        for window in windows {
            XCTAssertTrue(
                (0...100).contains(window.usedPercent),
                "\(window.id) reported \(window.usedPercent)"
            )
            XCTAssertGreaterThan(window.windowDuration, 0)
            XCTAssertFalse(window.source.isEmpty)
        }
    }
}
