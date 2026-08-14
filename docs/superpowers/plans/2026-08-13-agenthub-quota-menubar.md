# AgentHub Quota Menu Bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn AgentHub into a resident menu bar panel that shows subscription usage for Claude, Codex, Cursor, and OpenCode, and delete everything else.

**Architecture:** One SwiftUI application with no daemon, no IPC, and no database. A new `AgentHubQuota` module holds the four quota readers and the `QuotaWindow` model; the app renders an `NSStatusItem` whose hover shows a non-activating panel. Fourteen modules become two.

**Tech Stack:** Swift 6, SwiftUI + AppKit (`NSStatusItem`, `NSPanel`), XCTest, xcodegen, SQLite3 (Cursor token read), Security.framework (Keychain).

**Spec:** `docs/superpowers/specs/2026-08-13-agenthub-quota-menubar-design.md`

## Global Constraints

- Deployment target macOS 14.0; `SWIFT_VERSION: 6.0`; `SWIFT_STRICT_CONCURRENCY: complete`.
- A provider token is read at the moment of the request, held in memory for that request only, and never written to disk, a log, or any view. `scripts/check.sh` enforces this and must keep passing.
- Timestamp parsing must accept fractional seconds (`2026-08-12T14:50:00.458358+00:00`) and whole seconds. A window whose percentage or reset time is missing is skipped, never rendered as 0%.
- Windows are named by duration (`5h`, `7d`, `30d`). Windows sharing a duration keep the provider's label. Ties order by window id so rows never reshuffle.
- Quota API calls are rate-limited to 900s; a failed refresh keeps the previous reading.
- Every task ends with `zsh scripts/check.sh` green before its commit.

---

## File Structure

**Created**

| File | Responsibility |
|---|---|
| `Sources/AgentHubQuota/QuotaWindow.swift` | `Provider`, `QuotaWindow`, duration naming, staleness |
| `Sources/AgentHubQuota/ClaudeQuota.swift` | Anthropic OAuth usage endpoint + Keychain credential |
| `Sources/AgentHubQuota/CodexQuota.swift` | `codex app-server` rate limits |
| `Sources/AgentHubQuota/CursorQuota.swift` | cursor.com usage summary + token read + authorisation flag |
| `Sources/AgentHubQuota/OpenCodeQuota.swift` | opencode.ai zen usage |
| `Sources/AgentHubQuota/QuotaService.swift` | Aggregates the four, owns the refresh interval |
| `App/MenuBar/MenuBarController.swift` | `NSStatusItem`, hover tracking, panel presentation |
| `App/MenuBar/HoverController.swift` | Hover delay/cancel state machine (unit tested) |
| `App/MenuBar/QuotaPanelView.swift` | The panel itself, large numerals |
| `App/MenuBar/GlobalHotKey.swift` | Configurable shortcut registration |
| `App/Settings/SettingsView.swift` | Hotkey binding, Cursor authorisation |
| `App/Migration/LegacyUninstaller.swift` | Removes LaunchAgent, Claude hooks, Cursor hooks |

**Deleted:** `Sources/agenthubd`, `Sources/AgentHubDaemon`, `Sources/AgentHubIPC`, `Sources/AgentHubPersistence`, `Sources/AgentHubCore`, `Sources/AgentHubClaude`, `Sources/AgentHubCursor`, `Sources/AgentHubOpenCode`, `Sources/AgentHubCodex`, `Sources/AgentHubTestSupport`, `Sources/agenthub-claude-hook`, `Sources/agenthub-claude-statusline`, `Sources/agenthub-cursor-hook`, `App/Features/{Dashboard,Sessions,Requests,Health,Claude,OpenCode}`, `App/{DaemonClient,DaemonInstallation,AppEnvironment,JumpOpener,AXClaudeAccessibilitySurface,ClaudeNativeInteractionExecutor}.swift`, `Support/install-daemon.sh`, `Support/uninstall-daemon.sh`, `Support/com.agenthub.daemon.plist`.

---

### Task 1: Create the AgentHubQuota module with the quota model

**Files:**
- Create: `Sources/AgentHubQuota/QuotaWindow.swift`
- Modify: `Package.swift`
- Test: `Tests/AgentHubQuotaTests/QuotaWindowTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `Provider` (`.claude`, `.codex`, `.cursor`, `.openCode`, `rawValue: String`, `displayName: String`); `QuotaWindow` with `init(provider:accountID:windowID:label:plan:usedPercent:windowDuration:resetsAt:fetchedAt:source:) throws`, properties `id: String`, `windowID: String?`, `label: String?`, `plan: String?`, `usedPercent: Double`, `windowDuration: TimeInterval`, `resetsAt: Date`, `fetchedAt: Date`, `source: String`; `QuotaWindow.durationLabel(_ duration: TimeInterval) -> String`; `canonicalLabel: String`; `isStale(now:sourceTTL:) -> Bool`; `ModelValidationError`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AgentHubQuotaTests/QuotaWindowTests.swift
import XCTest
@testable import AgentHubQuota

final class QuotaWindowTests: XCTestCase {
    func testDurationLabelUsesHoursThenDays() {
        XCTAssertEqual(QuotaWindow.durationLabel(5 * 3_600), "5h")
        XCTAssertEqual(QuotaWindow.durationLabel(7 * 24 * 3_600), "7d")
        XCTAssertEqual(QuotaWindow.durationLabel(30 * 24 * 3_600), "30d")
    }

    func testIdentityIncludesWindowIDSoSiblingsStayDistinct() throws {
        func window(_ id: String) throws -> QuotaWindow {
            try QuotaWindow(
                provider: .cursor, accountID: "a", windowID: id,
                usedPercent: 10, windowDuration: 31 * 24 * 3_600,
                resetsAt: Date(timeIntervalSince1970: 2_000),
                fetchedAt: Date(timeIntervalSince1970: 1_000),
                source: "cursor-dashboard"
            )
        }
        XCTAssertNotEqual(try window("api").id, try window("auto").id)
    }

    func testPercentOutOfRangeIsRejected() {
        XCTAssertThrowsError(
            try QuotaWindow(
                provider: .claude, accountID: "a", usedPercent: 101,
                windowDuration: 3_600, resetsAt: Date(), fetchedAt: Date(),
                source: "t"
            )
        )
    }

    func testStalenessUsesFetchedAt() throws {
        let window = try QuotaWindow(
            provider: .claude, accountID: "a", usedPercent: 10,
            windowDuration: 3_600, resetsAt: Date(timeIntervalSince1970: 10_000),
            fetchedAt: Date(timeIntervalSince1970: 1_000), source: "t"
        )
        XCTAssertFalse(window.isStale(now: Date(timeIntervalSince1970: 1_100)))
        XCTAssertTrue(window.isStale(now: Date(timeIntervalSince1970: 2_000)))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter QuotaWindowTests`
Expected: FAIL — `no such module 'AgentHubQuota'`.

- [ ] **Step 3: Create the module by moving the model out of AgentHubCore**

```bash
mkdir -p Sources/AgentHubQuota Tests/AgentHubQuotaTests
```

Create `Sources/AgentHubQuota/QuotaWindow.swift` containing **only** these
declarations, copied verbatim from `Sources/AgentHubCore/Models.swift`: the
`Provider` enum (with its `displayName`), `ModelValidationError` reduced to the
two cases `quotaPercentOutOfRange` and `nonPositiveWindowDuration`, and the whole
`QuotaWindow` struct including `isStale(now:sourceTTL:)`, `durationLabel(_:)`,
`canonicalLabel`, and `availablePace(now:)`.

Do not copy sessions, nodes, requests, envelopes, or events.

- [ ] **Step 4: Register the target**

In `Package.swift`, add to `products`:

```swift
.library(name: "AgentHubQuota", targets: ["AgentHubQuota"]),
```

and to `targets`:

```swift
.target(
    name: "AgentHubQuota",
    linkerSettings: [
        .linkedFramework("Security"),
        .linkedLibrary("sqlite3"),
    ]
),
.testTarget(name: "AgentHubQuotaTests", dependencies: ["AgentHubQuota"]),
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter QuotaWindowTests`
Expected: PASS, 4 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/AgentHubQuota Tests/AgentHubQuotaTests Package.swift
git commit -m "feat: add AgentHubQuota module with the quota window model"
```

---

### Task 2: Move the four quota readers into AgentHubQuota

**Files:**
- Create: `Sources/AgentHubQuota/{ClaudeQuota,CodexQuota,CursorQuota,OpenCodeQuota}.swift`
- Create: `Sources/AgentHubQuota/CodexRPC/{CodexRPCClient,CodexProcess,JSONRPC,JSONValue}.swift`
- Test: `Tests/AgentHubQuotaTests/{ClaudeQuotaTests,CodexQuotaTests,CursorQuotaTests,OpenCodeQuotaTests}.swift`

**Interfaces:**
- Consumes: `QuotaWindow`, `Provider` from Task 1.
- Produces: `ClaudeUsageAPIClient.fetch() async -> [QuotaWindow]`, `CodexQuotaClient.fetch() async -> [QuotaWindow]`, `CursorQuotaClient.fetchWindows(token:) async throws -> [QuotaWindow]` plus `CursorQuotaCollector` (`isAuthorized`, `authorize()`, `revoke()`, `refresh()`), `OpenCodeGoQuotaClient.fetch() async -> [QuotaWindow]`. Each client exposes `static let source: String` with values `claude-usage-api`, `codex-app-server`, `cursor-dashboard`, `opencode-go`.

- [ ] **Step 1: Move the source files**

```bash
git mv Sources/AgentHubClaude/ClaudeUsageAPI.swift Sources/AgentHubQuota/ClaudeQuota.swift
git mv Sources/AgentHubCursor/CursorQuotaClient.swift Sources/AgentHubQuota/CursorQuota.swift
git mv Sources/AgentHubCursor/CursorLoginSessionReader.swift Sources/AgentHubQuota/CursorLoginSessionReader.swift
git mv Sources/AgentHubCursor/CursorQuotaAuthStore.swift Sources/AgentHubQuota/CursorQuotaAuthStore.swift
git mv Sources/AgentHubCursor/CursorQuotaCollector.swift Sources/AgentHubQuota/CursorQuotaCollector.swift
git mv Sources/AgentHubOpenCode/OpenCodeGoQuota.swift Sources/AgentHubQuota/OpenCodeQuota.swift
mkdir -p Sources/AgentHubQuota/CodexRPC
git mv Sources/AgentHubCodex/CodexRPCClient.swift Sources/AgentHubQuota/CodexRPC/CodexRPCClient.swift
git mv Sources/AgentHubCodex/CodexProcess.swift Sources/AgentHubQuota/CodexRPC/CodexProcess.swift
git mv Sources/AgentHubCodex/JSONRPC.swift Sources/AgentHubQuota/CodexRPC/JSONRPC.swift
git mv Sources/AgentHubCodex/JSONValue.swift Sources/AgentHubQuota/CodexRPC/JSONValue.swift
```

Then in each moved file replace `import AgentHubCore` with nothing (the model is
now in the same module) and delete any `import AgentHubIPC`.

- [ ] **Step 2: Write the failing Codex quota test**

`CodexQuotaClient` is new: the old rate-limit parsing lived inside
`CodexAdapter`, which is being deleted. It keeps the snake_case handling.

```swift
// Tests/AgentHubQuotaTests/CodexQuotaTests.swift
import XCTest
@testable import AgentHubQuota

final class CodexQuotaTests: XCTestCase {
    private let live = """
    {"rateLimits":{"limit_id":"codex","plan_type":"plus",
      "primary":{"used_percent":98.0,"window_minutes":10080,"resets_at":1787012257},
      "secondary":{"used_percent":12.5,"window_minutes":300,"resets_at":1787000000}}}
    """

    func testDecodesSnakeCaseWindows() throws {
        let windows = try CodexQuotaDecoder(accountID: "default")
            .decode(Data(live.utf8), now: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows.map(\.usedPercent).sorted(), [12.5, 98])
        XCTAssertEqual(Set(windows.map(\.windowDuration)), [300 * 60, 10_080 * 60])
        XCTAssertEqual(Set(windows.map(\.id)).count, 2)
        XCTAssertTrue(windows.allSatisfy { $0.plan == "plus" })
        XCTAssertTrue(windows.allSatisfy { $0.source == "codex-app-server" })
    }

    func testMalformedPayloadYieldsNoWindows() throws {
        let windows = try CodexQuotaDecoder(accountID: "default")
            .decode(Data("{ not json".utf8), now: Date())
        XCTAssertTrue(windows.isEmpty)
    }
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `swift test --filter CodexQuotaTests`
Expected: FAIL — `cannot find 'CodexQuotaDecoder' in scope`.

- [ ] **Step 4: Write CodexQuota.swift**

```swift
// Sources/AgentHubQuota/CodexQuota.swift
import Foundation

/// Decodes the Codex app server's rate-limit snapshot. Codex reports
/// snake_case; both spellings are accepted so an older or newer server still
/// parses rather than silently yielding no windows.
public struct CodexQuotaDecoder: Sendable {
    public static let source = "codex-app-server"

    private let accountID: String

    public init(accountID: String) { self.accountID = accountID }

    public func decode(_ data: Data, now: Date) throws -> [QuotaWindow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = root["rateLimits"] as? [String: Any] else { return [] }
        let plan = limits["plan_type"] as? String ?? limits["planType"] as? String
        return ["primary", "secondary"].compactMap { key in
            guard let entry = limits[key] as? [String: Any] else { return nil }
            return window(entry, windowID: key, plan: plan, now: now)
        }
    }

    private func window(
        _ entry: [String: Any],
        windowID: String,
        plan: String?,
        now: Date
    ) -> QuotaWindow? {
        guard let used = number(entry["used_percent"] ?? entry["usedPercent"]),
              let minutes = number(entry["window_minutes"] ?? entry["windowDurationMins"]),
              let reset = number(entry["resets_at"] ?? entry["resetsAt"]) else { return nil }
        let duration = minutes * 60
        return try? QuotaWindow(
            provider: .codex,
            accountID: accountID,
            windowID: windowID,
            label: QuotaWindow.durationLabel(duration),
            plan: plan,
            usedPercent: used,
            windowDuration: duration,
            resetsAt: Date(timeIntervalSince1970: reset),
            fetchedAt: now,
            source: Self.source
        )
    }

    private func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }
}

/// Fetches Codex usage by running `codex app-server` for a single call.
public struct CodexQuotaClient: Sendable {
    private let decoder: CodexQuotaDecoder
    private let now: @Sendable () -> Date

    public init(
        accountID: String = "default",
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.decoder = CodexQuotaDecoder(accountID: accountID)
        self.now = now
    }

    /// Returns no windows when Codex is absent or the call fails, so this one
    /// source degrades rather than the whole panel.
    public func fetch() async -> [QuotaWindow] {
        guard let process = try? CodexProcess.launchAppServer() else { return [] }
        defer { process.terminate() }
        guard let result = try? await process.call(
            method: "account/rateLimits/read",
            params: nil,
            timeout: .seconds(10)
        ) else { return [] }
        return (try? decoder.decode(result, now: now())) ?? []
    }
}
```

If `CodexProcess` does not already expose `launchAppServer()` and a
`call(method:params:timeout:) async throws -> Data` returning the raw JSON of
the `result` field, add them there, reusing the existing `CodexRPCClient`
plumbing rather than writing a second JSON-RPC implementation.

- [ ] **Step 5: Give CursorQuotaCollector the two members later tasks need**

`CursorQuotaCollector` is an actor whose `lastErrorMessage` is `private` and
which has no convenience constructor. Tasks 3 and 8 need both.

In `Sources/AgentHubQuota/CursorQuotaCollector.swift`, change the stored
property to keep its setter private while exposing the value:

```swift
    public private(set) var lastErrorMessage: String?
```

and add:

```swift
    /// The collector wired to this Mac's Cursor installation.
    public static func live(accountID: String = "default") -> CursorQuotaCollector {
        CursorQuotaCollector(
            auth: CursorQuotaAuthStore(),
            reader: CursorLoginSessionReader(),
            client: CursorQuotaClient(accountID: accountID),
            // cursor.com is an external API and a billing-cycle percentage moves
            // slowly, so poll well inside the staleness threshold but no faster.
            pollInterval: .seconds(900)
        )
    }
```

- [ ] **Step 6: Move the existing reader tests**

```bash
git mv Tests/AgentHubClaudeTests/ClaudeUsageAPITests.swift Tests/AgentHubQuotaTests/ClaudeQuotaTests.swift
git mv Tests/AgentHubCursorTests/CursorSessionCookieTests.swift Tests/AgentHubQuotaTests/CursorQuotaTests.swift
git mv Tests/AgentHubCursorTests/CursorQuotaPrivacyTests.swift Tests/AgentHubQuotaTests/CursorQuotaPrivacyTests.swift
git mv Tests/AgentHubOpenCodeTests/OpenCodeGoQuotaTests.swift Tests/AgentHubQuotaTests/OpenCodeQuotaTests.swift
git mv Tests/AgentHubOpenCodeTests/OpenCodeGoQuotaCacheTests.swift Tests/AgentHubQuotaTests/OpenCodeQuotaCacheTests.swift
```

In each, change `@testable import AgentHubClaude` / `AgentHubCursor` /
`AgentHubOpenCode` to `@testable import AgentHubQuota` and drop
`import AgentHubCore`.

- [ ] **Step 7: Run the module's tests**

Run: `swift test --filter AgentHubQuotaTests`
Expected: PASS. Claude's fractional-second cases and Cursor's `<sub>::<jwt>`
cookie cases must be among them.

- [ ] **Step 8: Commit**

```bash
git add -A Sources/AgentHubQuota Tests/AgentHubQuotaTests
git commit -m "refactor: move the four quota readers into AgentHubQuota"
```

---

### Task 3: Add the aggregating quota service

**Files:**
- Create: `Sources/AgentHubQuota/QuotaService.swift`
- Test: `Tests/AgentHubQuotaTests/QuotaServiceTests.swift`

**Interfaces:**
- Consumes: the four clients from Task 2.
- Produces: `actor QuotaService` with `init(sources: [QuotaSource], minimumInterval: TimeInterval = 900, now: @escaping @Sendable () -> Date = { Date() })`, `func windows(force: Bool = false) async -> [QuotaWindow]`, and `struct QuotaSource { let provider: Provider; let fetch: @Sendable () async -> [QuotaWindow] }`. Also `static func live() -> QuotaService`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AgentHubQuotaTests/QuotaServiceTests.swift
import XCTest
@testable import AgentHubQuota

final class QuotaServiceTests: XCTestCase {
    private func window(_ provider: Provider, _ pct: Double, at date: Date) throws -> QuotaWindow {
        try QuotaWindow(
            provider: provider, accountID: "a", windowID: "w", usedPercent: pct,
            windowDuration: 3_600, resetsAt: date.addingTimeInterval(3_600),
            fetchedAt: date, source: "test"
        )
    }

    func testMergesEveryProvider() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let service = QuotaService(
            sources: [
                .init(provider: .claude, fetch: { [try! self.window(.claude, 10, at: now)] }),
                .init(provider: .codex, fetch: { [try! self.window(.codex, 20, at: now)] }),
            ],
            now: { now }
        )

        let windows = await service.windows()

        XCTAssertEqual(Set(windows.map(\.provider)), [.claude, .codex])
    }

    func testOneFailingSourceDoesNotBlockOthers() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let service = QuotaService(
            sources: [
                .init(provider: .claude, fetch: { [] }),
                .init(provider: .codex, fetch: { [try! self.window(.codex, 20, at: now)] }),
            ],
            now: { now }
        )

        let windows = await service.windows()

        XCTAssertEqual(windows.map(\.provider), [.codex])
    }

    func testSecondCallInsideIntervalDoesNotRefetch() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let counter = Counter()
        let service = QuotaService(
            sources: [.init(provider: .claude, fetch: {
                await counter.increment()
                return [try! self.window(.claude, 10, at: now)]
            })],
            minimumInterval: 900,
            now: { now }
        )

        _ = await service.windows()
        _ = await service.windows()

        let calls = await counter.count
        XCTAssertEqual(calls, 1)
    }

    func testForceBypassesTheInterval() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let counter = Counter()
        let service = QuotaService(
            sources: [.init(provider: .claude, fetch: {
                await counter.increment()
                return [try! self.window(.claude, 10, at: now)]
            })],
            minimumInterval: 900,
            now: { now }
        )

        _ = await service.windows()
        _ = await service.windows(force: true)

        let calls = await counter.count
        XCTAssertEqual(calls, 2)
    }

    func testFailedRefreshKeepsPreviousWindows() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let empty = Flag()
        let service = QuotaService(
            sources: [.init(provider: .claude, fetch: {
                await empty.value ? [] : [try! self.window(.claude, 10, at: now)]
            })],
            minimumInterval: 0,
            now: { now }
        )

        _ = await service.windows()
        await empty.set(true)
        let after = await service.windows()

        XCTAssertEqual(after.map(\.usedPercent), [10])
    }
}

private actor Counter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private actor Flag {
    private(set) var value = false
    func set(_ newValue: Bool) { value = newValue }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter QuotaServiceTests`
Expected: FAIL — `cannot find 'QuotaService' in scope`.

- [ ] **Step 3: Implement QuotaService**

```swift
// Sources/AgentHubQuota/QuotaService.swift
import Foundation

/// One provider's contribution to the panel.
public struct QuotaSource: Sendable {
    public let provider: Provider
    public let fetch: @Sendable () async -> [QuotaWindow]

    public init(provider: Provider, fetch: @escaping @Sendable () async -> [QuotaWindow]) {
        self.provider = provider
        self.fetch = fetch
    }
}

/// Collects every provider's usage behind one rate limit.
///
/// Sources are independent: a provider that is signed out or unreachable
/// returns no windows and the others are unaffected. An empty result never
/// replaces a previous reading, so a transient failure leaves the last real
/// numbers on screen rather than blanking the panel.
public actor QuotaService {
    private let sources: [QuotaSource]
    private let minimumInterval: TimeInterval
    private let now: @Sendable () -> Date

    private var cached: [Provider: [QuotaWindow]] = [:]
    private var lastAttempt: Date?

    public init(
        sources: [QuotaSource],
        minimumInterval: TimeInterval = 900,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sources = sources
        self.minimumInterval = minimumInterval
        self.now = now
    }

    /// - Parameter force: bypasses the interval for an explicit refresh.
    public func windows(force: Bool = false) async -> [QuotaWindow] {
        if !force, let lastAttempt,
           now().timeIntervalSince(lastAttempt) < minimumInterval {
            return flattened()
        }
        lastAttempt = now()

        await withTaskGroup(of: (Provider, [QuotaWindow]).self) { group in
            for source in sources {
                group.addTask { (source.provider, await source.fetch()) }
            }
            for await (provider, fetched) in group where !fetched.isEmpty {
                cached[provider] = fetched
            }
        }
        return flattened()
    }

    private func flattened() -> [QuotaWindow] {
        cached.values.flatMap { $0 }
    }

    /// The four real providers.
    public static func live() -> QuotaService {
        let claude = ClaudeUsageAPIClient()
        let codex = CodexQuotaClient()
        let cursor = CursorQuotaCollector.live()
        let openCode = OpenCodeGoQuotaClient()
        return QuotaService(sources: [
            .init(provider: .claude) { await claude.fetch() },
            .init(provider: .codex) { await codex.fetch() },
            .init(provider: .cursor) { await cursor.currentWindows() },
            .init(provider: .openCode) { await openCode.fetch() },
        ])
    }
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `swift test --filter QuotaServiceTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentHubQuota/QuotaService.swift Tests/AgentHubQuotaTests/QuotaServiceTests.swift
git commit -m "feat: aggregate every provider's usage behind one rate limit"
```

---

### Task 4: Quota presentation, with large numerals

**Files:**
- Create: `App/MenuBar/QuotaPresentation.swift`
- Test: `Tests/AgentHubAppTests/QuotaPresentationTests.swift`
- Modify: `project.yml`

**Interfaces:**
- Consumes: `QuotaWindow`, `Provider`.
- Produces: `QuotaPresentation` (`id`, `title`, `displayPercent`, `usedPercent`, `resetsAt`, `isStale`, `hasElapsed`, `informsRecommendations`) and `QuotaProviderRow` (`id`, `provider`, `windows`, `displayName`) with `static func rows(from:now:) -> [QuotaProviderRow]`.

This is the existing `App/Features/Quota/QuotaPresentation.swift`, moved and kept
whole — its naming, ordering, rounding, and stale/ended rules are already
correct and tested.

- [ ] **Step 1: Move the file and its tests**

```bash
mkdir -p App/MenuBar
git mv App/Features/Quota/QuotaPresentation.swift App/MenuBar/QuotaPresentation.swift
```

Create `Tests/AgentHubAppTests/QuotaPresentationTests.swift` by copying, from
`Tests/AgentHubAppTests/DashboardViewModelTests.swift`, exactly these tests and
nothing else:

`testClaudeQuotaPresentationUsesWindowAndPlanLabels`,
`testClaudeSessionWindowIsNamedByDuration`,
`testUnlabeledQuotaPresentationFallsBackToDuration`,
`testElapsedWindowIsMarkedExpired`, `testCurrentWindowIsNotMarkedExpired`,
`testWindowsSharingADurationKeepTheirProviderLabel`,
`testWindowsWithDistinctDurationsStayDurationOnly`,
`testFractionalPercentIsRoundedForDisplay`,
`testQuotaRowsGroupByProviderAndSortShortestWindowFirst`,
`testSameDurationWindowsOrderIndependentlyOfInputOrder`.

Change `import AgentHubCore` to `import AgentHubQuota`.

- [ ] **Step 2: Point the app target at the new module**

In `project.yml`, under `targets.AgentHubApp.dependencies`, replace the
`AgentHubCore`, `AgentHubIPC`, and `AgentHubSecurity` entries with:

```yaml
    dependencies:
      - package: AgentHubPackage
        product: AgentHubQuota
```

and delete the `Support/com.agenthub.daemon.plist` resource entry and the whole
`postBuildScripts` section.

- [ ] **Step 3: Run the tests**

Run: `xcodegen generate && xcodebuild -project AgentHub.xcodeproj -scheme AgentHubApp -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO test`
Expected: PASS — 10 presentation tests.

- [ ] **Step 4: Commit**

```bash
git add -A App project.yml Tests/AgentHubAppTests
git commit -m "refactor: move quota presentation to the menu bar feature"
```

---

### Task 5: Hover state machine

**Files:**
- Create: `App/MenuBar/HoverController.swift`
- Test: `Tests/AgentHubAppTests/HoverControllerTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `@MainActor final class HoverController` with `init(delay: TimeInterval = 0.3, schedule: @escaping (TimeInterval, @escaping () -> Void) -> Cancellable)`, methods `mouseEntered()`, `mouseExited()`, `pin()`, `unpin()`, properties `isVisible: Bool`, `isPinned: Bool`, and `var onVisibilityChange: ((Bool) -> Void)?`. `Cancellable` is a protocol with `cancel()`.

Keeping the timing rules in a plain object means they can be tested without a
menu bar.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AgentHubAppTests/HoverControllerTests.swift
import XCTest
@testable import AgentHubApp

@MainActor
final class HoverControllerTests: XCTestCase {
    /// Fires scheduled work by hand so the delay is deterministic.
    private final class ManualScheduler {
        private var pending: [() -> Void] = []
        func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) -> Cancellable {
            pending.append(work)
            let index = pending.count - 1
            return Token { [weak self] in self?.pending[index] = {} }
        }
        func fireAll() {
            let work = pending
            pending = []
            work.forEach { $0() }
        }
        private final class Token: Cancellable {
            private let onCancel: () -> Void
            init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
            func cancel() { onCancel() }
        }
    }

    func testHoverShowsOnlyAfterTheDelay() {
        let scheduler = ManualScheduler()
        let controller = HoverController(delay: 0.3, schedule: scheduler.schedule)

        controller.mouseEntered()
        XCTAssertFalse(controller.isVisible, "must not appear before the delay")

        scheduler.fireAll()
        XCTAssertTrue(controller.isVisible)
    }

    func testLeavingBeforeTheDelayNeverShows() {
        let scheduler = ManualScheduler()
        let controller = HoverController(delay: 0.3, schedule: scheduler.schedule)

        controller.mouseEntered()
        controller.mouseExited()
        scheduler.fireAll()

        XCTAssertFalse(controller.isVisible, "sweeping past the icon must not open it")
    }

    func testLeavingHidesAnUnpinnedPanel() {
        let scheduler = ManualScheduler()
        let controller = HoverController(delay: 0.3, schedule: scheduler.schedule)
        controller.mouseEntered()
        scheduler.fireAll()

        controller.mouseExited()

        XCTAssertFalse(controller.isVisible)
    }

    func testPinnedPanelSurvivesMouseExit() {
        let scheduler = ManualScheduler()
        let controller = HoverController(delay: 0.3, schedule: scheduler.schedule)
        controller.mouseEntered()
        scheduler.fireAll()
        controller.pin()

        controller.mouseExited()

        XCTAssertTrue(controller.isVisible)
        XCTAssertTrue(controller.isPinned)
    }

    func testUnpinHidesImmediately() {
        let scheduler = ManualScheduler()
        let controller = HoverController(delay: 0.3, schedule: scheduler.schedule)
        controller.mouseEntered()
        scheduler.fireAll()
        controller.pin()

        controller.unpin()

        XCTAssertFalse(controller.isVisible)
    }

    func testVisibilityChangesAreReportedOnce() {
        let scheduler = ManualScheduler()
        let controller = HoverController(delay: 0.3, schedule: scheduler.schedule)
        var changes: [Bool] = []
        controller.onVisibilityChange = { changes.append($0) }

        controller.mouseEntered()
        scheduler.fireAll()
        controller.mouseEntered()
        controller.mouseExited()

        XCTAssertEqual(changes, [true, false])
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild ... test -only-testing:AgentHubAppTests/HoverControllerTests`
Expected: FAIL — `cannot find 'HoverController' in scope`.

- [ ] **Step 3: Implement HoverController**

```swift
// App/MenuBar/HoverController.swift
import Foundation

public protocol Cancellable: AnyObject {
    func cancel()
}

/// Decides when the quota panel is on screen.
///
/// Hover opens the panel only after a short delay, so moving the pointer across
/// the menu bar to reach another item does not flash it open. Pinning survives
/// mouse exit; unpinning closes at once.
@MainActor
final class HoverController {
    private let delay: TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> Cancellable

    private var pendingShow: Cancellable?
    private(set) var isVisible = false {
        didSet {
            guard isVisible != oldValue else { return }
            onVisibilityChange?(isVisible)
        }
    }
    private(set) var isPinned = false

    var onVisibilityChange: ((Bool) -> Void)?

    init(
        delay: TimeInterval = 0.3,
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Cancellable
    ) {
        self.delay = delay
        self.schedule = schedule
    }

    func mouseEntered() {
        guard !isVisible, pendingShow == nil else { return }
        pendingShow = schedule(delay) { [weak self] in
            guard let self else { return }
            self.pendingShow = nil
            self.isVisible = true
        }
    }

    func mouseExited() {
        pendingShow?.cancel()
        pendingShow = nil
        guard !isPinned else { return }
        isVisible = false
    }

    func pin() {
        pendingShow?.cancel()
        pendingShow = nil
        isPinned = true
        isVisible = true
    }

    func unpin() {
        isPinned = false
        isVisible = false
    }
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `xcodebuild ... test -only-testing:AgentHubAppTests/HoverControllerTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add App/MenuBar/HoverController.swift Tests/AgentHubAppTests/HoverControllerTests.swift
git commit -m "feat: add the menu bar hover state machine"
```

---

### Task 6: The panel view

**Files:**
- Create: `App/MenuBar/QuotaPanelView.swift`
- Create: `App/MenuBar/QuotaPanelModel.swift`
- Test: `Tests/AgentHubAppTests/QuotaPanelModelTests.swift`

**Interfaces:**
- Consumes: `QuotaService`, `QuotaProviderRow`.
- Produces: `@MainActor final class QuotaPanelModel: ObservableObject` with `@Published private(set) var rows: [QuotaProviderRow]`, `@Published private(set) var isRefreshing: Bool`, `@Published private(set) var lastError: String?`, `func load(force: Bool) async`; and `struct QuotaPanelView: View` taking `@ObservedObject var model: QuotaPanelModel` and `var onOpenSettings: () -> Void`.

- [ ] **Step 1: Write the failing model test**

```swift
// Tests/AgentHubAppTests/QuotaPanelModelTests.swift
import XCTest
import AgentHubQuota
@testable import AgentHubApp

@MainActor
final class QuotaPanelModelTests: XCTestCase {
    private func window(_ provider: Provider, _ pct: Double) throws -> QuotaWindow {
        try QuotaWindow(
            provider: provider, accountID: "a", windowID: "w", usedPercent: pct,
            windowDuration: 5 * 3_600,
            resetsAt: Date(timeIntervalSince1970: 100_000),
            fetchedAt: Date(timeIntervalSince1970: 99_000),
            source: "test"
        )
    }

    func testLoadPublishesOneRowPerProvider() async throws {
        let service = QuotaService(
            sources: [
                .init(provider: .claude, fetch: { [try! self.window(.claude, 10)] }),
                .init(provider: .cursor, fetch: { [try! self.window(.cursor, 20)] }),
            ],
            minimumInterval: 0,
            now: { Date(timeIntervalSince1970: 99_100) }
        )
        let model = QuotaPanelModel(service: service, now: { Date(timeIntervalSince1970: 99_100) })

        await model.load(force: true)

        XCTAssertEqual(model.rows.map(\.provider), [.claude, .cursor])
    }

    func testRefreshingFlagClearsAfterLoad() async throws {
        let service = QuotaService(
            sources: [.init(provider: .claude, fetch: { [try! self.window(.claude, 10)] })],
            minimumInterval: 0,
            now: { Date(timeIntervalSince1970: 99_100) }
        )
        let model = QuotaPanelModel(service: service, now: { Date(timeIntervalSince1970: 99_100) })

        await model.load(force: true)

        XCTAssertFalse(model.isRefreshing)
    }

    func testNoProvidersReportingLeavesRowsEmptyWithoutError() async throws {
        let service = QuotaService(
            sources: [.init(provider: .claude, fetch: { [] })],
            minimumInterval: 0,
            now: { Date(timeIntervalSince1970: 99_100) }
        )
        let model = QuotaPanelModel(service: service, now: { Date(timeIntervalSince1970: 99_100) })

        await model.load(force: true)

        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNil(model.lastError)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild ... test -only-testing:AgentHubAppTests/QuotaPanelModelTests`
Expected: FAIL — `cannot find 'QuotaPanelModel' in scope`.

- [ ] **Step 3: Implement the model**

```swift
// App/MenuBar/QuotaPanelModel.swift
import Foundation
import AgentHubQuota

@MainActor
final class QuotaPanelModel: ObservableObject {
    @Published private(set) var rows: [QuotaProviderRow] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?

    private let service: QuotaService
    private let now: @Sendable () -> Date

    init(service: QuotaService, now: @escaping @Sendable () -> Date = { Date() }) {
        self.service = service
        self.now = now
    }

    func load(force: Bool) async {
        isRefreshing = true
        defer { isRefreshing = false }
        let windows = await service.windows(force: force)
        rows = QuotaProviderRow.rows(from: windows, now: now())
        // No providers reporting is a normal signed-out state, not an error.
        lastError = nil
    }
}
```

- [ ] **Step 4: Implement the view**

```swift
// App/MenuBar/QuotaPanelView.swift
import SwiftUI
import AgentHubQuota

/// The panel shown from the menu bar. The percentages are the point, so they
/// carry the visual weight; everything else is support.
struct QuotaPanelView: View {
    @ObservedObject var model: QuotaPanelModel
    var onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if model.rows.isEmpty {
                Text("No usage reported yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.rows) { row in
                    QuotaProviderSection(row: row)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var header: some View {
        HStack {
            Text("Usage").font(.headline)
            Spacer()
            Button {
                Task { await model.load(force: true) }
            } label: {
                if model.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(model.isRefreshing)
            .help("Refresh usage from every provider")

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
    }
}

private struct QuotaProviderSection: View {
    let row: QuotaProviderRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(row.displayName)
                .font(.caption.bold())
                .foregroundStyle(row.provider.accentColor)
            HStack(alignment: .top, spacing: 22) {
                ForEach(row.windows) { window in
                    QuotaFigure(window: window, tint: row.provider.accentColor)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct QuotaFigure: View {
    let window: QuotaPresentation
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(window.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if window.hasElapsed {
                    Text("ENDED").font(.caption2.bold()).foregroundStyle(.secondary)
                } else if window.isStale {
                    Text("STALE").font(.caption2.bold()).foregroundStyle(.orange)
                }
            }
            // Tabular figures keep the digits from shifting between refreshes.
            Text(window.displayPercent)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(window.hasElapsed ? Color.secondary : .primary)
            ProgressView(value: window.usedPercent, total: 100)
                .tint(window.hasElapsed ? .gray : tint)
                .frame(width: 120)
            Text(window.hasElapsed
                 ? "window ended"
                 : "resets \(window.resetsAt, style: .relative)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

extension Provider {
    /// Distinct hue per provider so sections separate at a glance.
    var accentColor: Color {
        switch self {
        case .claude: .orange
        case .codex: .green
        case .cursor: .blue
        case .openCode: .purple
        }
    }
}
```

- [ ] **Step 5: Run it to verify it passes**

Run: `xcodebuild ... test -only-testing:AgentHubAppTests/QuotaPanelModelTests`
Expected: PASS, 3 tests.

- [ ] **Step 6: Commit**

```bash
git add App/MenuBar Tests/AgentHubAppTests/QuotaPanelModelTests.swift
git commit -m "feat: render usage as a panel with large percentages"
```

---

### Task 7: Menu bar item, hover presentation, and pinning

**Files:**
- Create: `App/MenuBar/MenuBarController.swift`
- Modify: `App/AgentHubApp.swift`
- Modify: `project.yml`

**Interfaces:**
- Consumes: `HoverController`, `QuotaPanelModel`, `QuotaPanelView`.
- Produces: `@MainActor final class MenuBarController` with `init(model: QuotaPanelModel, onOpenSettings: @escaping () -> Void)` and `func install()`.

- [ ] **Step 1: Make the app an agent with no Dock icon**

In `project.yml`, under `targets.AgentHubApp.settings.base`, add:

```yaml
        INFOPLIST_KEY_LSUIElement: YES
```

- [ ] **Step 2: Implement the controller**

```swift
// App/MenuBar/MenuBarController.swift
import AppKit
import SwiftUI

/// Owns the status item and the panel it shows.
///
/// The panel is a non-activating `NSPanel` so showing it never steals focus
/// from the app the user is working in.
@MainActor
final class MenuBarController: NSObject {
    private let model: QuotaPanelModel
    private let onOpenSettings: () -> Void
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private lazy var hover = HoverController(schedule: Self.schedule)

    init(model: QuotaPanelModel, onOpenSettings: @escaping () -> Void) {
        self.model = model
        self.onOpenSettings = onOpenSettings
        super.init()
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "gauge.with.dots.needle.33percent",
            accessibilityDescription: "AgentHub usage"
        )
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        statusItem = item

        installTrackingArea(on: item)

        hover.onVisibilityChange = { [weak self] visible in
            visible ? self?.showPanel() : self?.hidePanel()
        }
    }

    private func installTrackingArea(on item: NSStatusItem) {
        guard let button = item.button else { return }
        let area = NSTrackingArea(
            rect: button.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        button.addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        hover.mouseEntered()
        // Refresh opportunistically: the panel should not open showing a number
        // the user already knows is old.
        Task { await model.load(force: false) }
    }

    override func mouseExited(with event: NSEvent) {
        hover.mouseExited()
    }

    @objc private func statusItemClicked() {
        hover.isPinned ? hover.unpin() : hover.pin()
    }

    private func showPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard let button = statusItem?.button,
              let buttonWindow = button.window else { return }
        let origin = buttonWindow.convertPoint(toScreen: button.frame.origin)
        panel.setFrameTopLeftPoint(
            NSPoint(x: origin.x - panel.frame.width / 2, y: origin.y - 6)
        )
        panel.orderFrontRegardless()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let view = QuotaPanelView(model: model, onOpenSettings: onOpenSettings)
        let hosting = NSHostingController(rootView: view)
        let panel = NSPanel(contentViewController: hosting)
        panel.styleMask = [.nonactivatingPanel, .fullSizeContentView]
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovable = false
        return panel
    }

    private static func schedule(
        _ delay: TimeInterval,
        _ work: @escaping () -> Void
    ) -> Cancellable {
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return WorkItemToken(item)
    }

    private final class WorkItemToken: Cancellable {
        private let item: DispatchWorkItem
        init(_ item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }
}
```

- [ ] **Step 3: Replace the app entry point**

```swift
// App/AgentHubApp.swift
import SwiftUI
import AgentHubQuota

@main
struct AgentHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView(cursor: delegate.cursorAuthorization)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let cursorAuthorization = CursorAuthorizationModel()
    private lazy var model = QuotaPanelModel(service: QuotaService.live())
    private lazy var menuBar = MenuBarController(model: model) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
    private var refreshTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar.install()
        refreshTask = Task { [model] in
            while !Task.isCancelled {
                await model.load(force: false)
                try? await Task.sleep(for: .seconds(900))
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTask?.cancel()
    }
}
```

- [ ] **Step 4: Build and verify by hand**

Run: `xcodegen generate && xcodebuild -project AgentHub.xcodeproj -scheme AgentHubApp -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build && open .build/xcode/Build/Products/Debug/AgentHubApp.app`
Expected: no Dock icon; a gauge icon in the menu bar; hovering opens the panel after ~0.3s with four provider sections; moving away closes it; clicking pins it.

- [ ] **Step 5: Commit**

```bash
git add App project.yml
git commit -m "feat: show usage from a menu bar item on hover"
```

---

### Task 8: Settings — Cursor authorisation and the hotkey

**Files:**
- Create: `App/Settings/SettingsView.swift`
- Create: `App/Settings/CursorAuthorizationModel.swift`
- Create: `App/MenuBar/GlobalHotKey.swift`
- Test: `Tests/AgentHubAppTests/GlobalHotKeyTests.swift`

**Interfaces:**
- Consumes: `CursorQuotaCollector`.
- Produces: `@MainActor final class CursorAuthorizationModel: ObservableObject` with `@Published private(set) var isAuthorized: Bool`, `func authorize() async`, `func revoke() async`; `struct SettingsView: View`; `struct HotKeyBinding: Equatable, Codable` with `keyCode: UInt32`, `modifiers: UInt32`, `displayName: String`, `static let `default`: HotKeyBinding`, and `static func load()/save(_:)` backed by `UserDefaults`.

- [ ] **Step 1: Write the failing hotkey test**

```swift
// Tests/AgentHubAppTests/GlobalHotKeyTests.swift
import XCTest
@testable import AgentHubApp

final class GlobalHotKeyTests: XCTestCase {
    func testDefaultBindingIsStable() {
        XCTAssertEqual(HotKeyBinding.default, HotKeyBinding.default)
        XCTAssertFalse(HotKeyBinding.default.displayName.isEmpty)
    }

    func testBindingRoundTripsThroughDefaults() throws {
        let defaults = UserDefaults(suiteName: "agenthub.tests.\(UUID().uuidString)")!
        let binding = HotKeyBinding(keyCode: 17, modifiers: 4096, displayName: "⌘⌥T")

        HotKeyBinding.save(binding, to: defaults)

        XCTAssertEqual(HotKeyBinding.load(from: defaults), binding)
    }

    func testMissingBindingFallsBackToTheDefault() {
        let defaults = UserDefaults(suiteName: "agenthub.tests.\(UUID().uuidString)")!
        XCTAssertEqual(HotKeyBinding.load(from: defaults), .default)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild ... test -only-testing:AgentHubAppTests/GlobalHotKeyTests`
Expected: FAIL — `cannot find 'HotKeyBinding' in scope`.

- [ ] **Step 3: Implement the binding and registration**

```swift
// App/MenuBar/GlobalHotKey.swift
import AppKit
import Carbon.HIToolbox

/// A user-configurable shortcut that reveals the pinned panel.
struct HotKeyBinding: Equatable, Codable {
    var keyCode: UInt32
    var modifiers: UInt32
    var displayName: String

    /// ⌥⌘U — unclaimed by macOS and mnemonic for "usage".
    static let `default` = HotKeyBinding(
        keyCode: UInt32(kVK_ANSI_U),
        modifiers: UInt32(optionKey | cmdKey),
        displayName: "⌥⌘U"
    )

    private static let key = "hotKeyBinding"

    static func load(from defaults: UserDefaults = .standard) -> HotKeyBinding {
        guard let data = defaults.data(forKey: key),
              let binding = try? JSONDecoder().decode(HotKeyBinding.self, from: data) else {
            return .default
        }
        return binding
    }

    static func save(_ binding: HotKeyBinding, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(binding) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Registers the shortcut with the window server.
@MainActor
final class GlobalHotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var onFire: (() -> Void)?

    func register(_ binding: HotKeyBinding, onFire: @escaping () -> Void) {
        unregister()
        self.onFire = onFire

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, context in
                guard let context else { return noErr }
                let key = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async { key.onFire?() }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )

        let id = EventHotKeyID(signature: OSType(0x41484B59), id: 1)
        RegisterEventHotKey(
            binding.keyCode,
            binding.modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &reference
        )
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil
        handler = nil
    }

    deinit { unregister() }
}
```

- [ ] **Step 4: Implement Cursor authorisation and the settings screen**

```swift
// App/Settings/CursorAuthorizationModel.swift
import Foundation
import AgentHubQuota

/// Cursor usage needs an explicit opt-in: reading it means reading the token
/// Cursor stored locally, which never happens without the user asking.
@MainActor
final class CursorAuthorizationModel: ObservableObject {
    @Published private(set) var isAuthorized = false
    @Published private(set) var message: String?

    private let collector = CursorQuotaCollector.live()

    init() {
        Task { await refreshState() }
    }

    func authorize() async {
        await collector.authorize()
        _ = try? await collector.refresh()
        await refreshState()
    }

    func revoke() async {
        await collector.revoke()
        await refreshState()
    }

    private func refreshState() async {
        isAuthorized = await collector.isAuthorized
        message = await collector.lastErrorMessage
    }
}
```

```swift
// App/Settings/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    @ObservedObject var cursor: CursorAuthorizationModel
    @State private var binding = HotKeyBinding.load()

    var body: some View {
        Form {
            Section("Shortcut") {
                LabeledContent("Show usage") {
                    Text(binding.displayName).monospaced()
                }
                Text("Press this anywhere to open the usage panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Cursor") {
                if cursor.isAuthorized {
                    LabeledContent("Usage reading") { Text("Active") }
                    Button("Revoke") { Task { await cursor.revoke() } }
                } else {
                    Text("Cursor usage requires reading the session token Cursor "
                         + "stores on this Mac. It is used for one request and never saved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Authorize usage reading") { Task { await cursor.authorize() } }
                }
                if let message = cursor.message {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
    }
}
```

- [ ] **Step 5: Wire the hotkey into the delegate**

In `App/AgentHubApp.swift`, add to `AppDelegate` a `private let hotKey = GlobalHotKey()` and, at the end of `applicationDidFinishLaunching`:

```swift
        hotKey.register(HotKeyBinding.load()) { [weak self] in
            self?.menuBar.revealPinned()
        }
```

Add to `MenuBarController`:

```swift
    /// Shows the panel pinned, for the global shortcut.
    func revealPinned() {
        hover.pin()
    }
```

- [ ] **Step 6: Run the tests and verify by hand**

Run: `xcodebuild ... test -only-testing:AgentHubAppTests/GlobalHotKeyTests`
Expected: PASS, 3 tests. Then launch the app and confirm ⌥⌘U opens the pinned panel and Settings shows the Cursor section.

- [ ] **Step 7: Commit**

```bash
git add App Tests/AgentHubAppTests/GlobalHotKeyTests.swift
git commit -m "feat: add a global shortcut and settings for Cursor authorization"
```

---

### Task 9: Uninstall the legacy daemon and hooks

**Files:**
- Create: `App/Migration/LegacyUninstaller.swift`
- Test: `Tests/AgentHubAppTests/LegacyUninstallerTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `struct LegacyUninstaller` with `init(claudeSettingsURL: URL, cursorHooksURL: URL, launchAgentURL: URL)`, `func run() throws -> Summary`, and `struct Summary { let removedClaudeHooks: Int; let removedCursorHooks: Int; let removedLaunchAgent: Bool }`.

Removing entries the user did not add is the whole risk here, so the tests are
about what must survive.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AgentHubAppTests/LegacyUninstallerTests.swift
import XCTest
@testable import AgentHubApp

final class LegacyUninstallerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agenthub-uninstall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRemovesAgentHubClaudeHooksAndKeepsForeignOnes() throws {
        let settings = directory.appendingPathComponent("settings.json")
        try Data("""
        {"statusLine":{"command":"payload=$(cat); '/x/AgentHub/bin/agenthub-claude-statusline'; sh ~/.claude/mine.sh"},
         "theme":"dark",
         "hooks":{"SessionStart":[
           {"hooks":[{"type":"command","command":"'/x/AgentHub/bin/agenthub-claude-hook'"}]},
           {"hooks":[{"type":"command","command":"'/Users/me/.local/bin/jcode' setup"}]}]}}
        """.utf8).write(to: settings)

        let summary = try LegacyUninstaller(
            claudeSettingsURL: settings,
            cursorHooksURL: directory.appendingPathComponent("absent-hooks.json"),
            launchAgentURL: directory.appendingPathComponent("absent.plist")
        ).run()

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: settings))
            as! [String: Any]
        let commands = ((root["hooks"] as! [String: Any])["SessionStart"] as! [[String: Any]])
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }

        XCTAssertEqual(summary.removedClaudeHooks, 1)
        XCTAssertEqual(commands.filter { $0.contains("agenthub") }.count, 0)
        XCTAssertEqual(commands.filter { $0.contains("jcode") }.count, 1)
        XCTAssertEqual(root["theme"] as? String, "dark", "unrelated settings survive")
        XCTAssertNil(root["statusLine"], "AgentHub's status line wrapper is removed")
    }

    func testRemovesAgentHubCursorHooksAndKeepsPeers() throws {
        let hooks = directory.appendingPathComponent("hooks.json")
        try Data("""
        {"version":1,"hooks":{"beforeShellExecution":[
          {"command":"'/x/AgentHub/bin/agenthub-cursor-hook'"},
          {"command":"'/Users/me/.openisland/hook'"}]}}
        """.utf8).write(to: hooks)

        let summary = try LegacyUninstaller(
            claudeSettingsURL: directory.appendingPathComponent("absent.json"),
            cursorHooksURL: hooks,
            launchAgentURL: directory.appendingPathComponent("absent.plist")
        ).run()

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: hooks))
            as! [String: Any]
        let commands = ((root["hooks"] as! [String: Any])["beforeShellExecution"] as! [[String: Any]])
            .compactMap { $0["command"] as? String }

        XCTAssertEqual(summary.removedCursorHooks, 1)
        XCTAssertEqual(commands, ["'/Users/me/.openisland/hook'"])
    }

    func testMissingFilesAreNotAnError() throws {
        let summary = try LegacyUninstaller(
            claudeSettingsURL: directory.appendingPathComponent("a.json"),
            cursorHooksURL: directory.appendingPathComponent("b.json"),
            launchAgentURL: directory.appendingPathComponent("c.plist")
        ).run()

        XCTAssertEqual(summary.removedClaudeHooks, 0)
        XCTAssertEqual(summary.removedCursorHooks, 0)
        XCTAssertFalse(summary.removedLaunchAgent)
    }

    func testABackupIsWrittenBeforeEditing() throws {
        let settings = directory.appendingPathComponent("settings.json")
        try Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"'/x/AgentHub/bin/agenthub-claude-hook'"}]}]}}"#.utf8)
            .write(to: settings)

        _ = try LegacyUninstaller(
            claudeSettingsURL: settings,
            cursorHooksURL: directory.appendingPathComponent("absent.json"),
            launchAgentURL: directory.appendingPathComponent("absent.plist")
        ).run()

        let backups = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains("backup") }
        XCTAssertEqual(backups.count, 1)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild ... test -only-testing:AgentHubAppTests/LegacyUninstallerTests`
Expected: FAIL — `cannot find 'LegacyUninstaller' in scope`.

- [ ] **Step 3: Implement the uninstaller**

```swift
// App/Migration/LegacyUninstaller.swift
import Foundation

/// Removes what earlier versions of AgentHub installed on this Mac.
///
/// Ownership is decided by the command resolving to an AgentHub helper, so
/// hooks from other tools are never touched. Every file is backed up before it
/// is rewritten.
struct LegacyUninstaller {
    struct Summary {
        let removedClaudeHooks: Int
        let removedCursorHooks: Int
        let removedLaunchAgent: Bool
    }

    private let claudeSettingsURL: URL
    private let cursorHooksURL: URL
    private let launchAgentURL: URL

    init(claudeSettingsURL: URL, cursorHooksURL: URL, launchAgentURL: URL) {
        self.claudeSettingsURL = claudeSettingsURL
        self.cursorHooksURL = cursorHooksURL
        self.launchAgentURL = launchAgentURL
    }

    static func standard() -> LegacyUninstaller {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return LegacyUninstaller(
            claudeSettingsURL: home.appendingPathComponent(".claude/settings.json"),
            cursorHooksURL: home.appendingPathComponent(".cursor/hooks.json"),
            launchAgentURL: home.appendingPathComponent(
                "Library/LaunchAgents/com.agenthub.daemon.plist"
            )
        )
    }

    func run() throws -> Summary {
        Summary(
            removedClaudeHooks: try cleanClaude(),
            removedCursorHooks: try cleanCursor(),
            removedLaunchAgent: removeLaunchAgent()
        )
    }

    private func isOwned(_ command: String) -> Bool {
        command.contains("agenthub-claude-hook")
            || command.contains("agenthub-claude-statusline")
            || command.contains("agenthub-cursor-hook")
    }

    private func cleanClaude() throws -> Int {
        guard var root = try loadObject(claudeSettingsURL) else { return 0 }
        try backup(claudeSettingsURL)
        var removed = 0

        if let statusLine = root["statusLine"] as? [String: Any],
           let command = statusLine["command"] as? String,
           isOwned(command) {
            root.removeValue(forKey: "statusLine")
        }

        if var hooks = root["hooks"] as? [String: Any] {
            for (event, value) in hooks {
                guard let matchers = value as? [[String: Any]] else { continue }
                let remaining: [[String: Any]] = matchers.compactMap { matcher in
                    var matcher = matcher
                    guard let entries = matcher["hooks"] as? [[String: Any]] else { return matcher }
                    let kept = entries.filter { entry in
                        guard let command = entry["command"] as? String else { return true }
                        if isOwned(command) { removed += 1; return false }
                        return true
                    }
                    if kept.isEmpty && matcher.count == 1 { return nil }
                    matcher["hooks"] = kept
                    return matcher
                }
                hooks[event] = remaining.isEmpty ? nil : remaining
            }
            root["hooks"] = hooks.isEmpty ? nil : hooks
        }

        try write(root, to: claudeSettingsURL)
        return removed
    }

    private func cleanCursor() throws -> Int {
        guard var root = try loadObject(cursorHooksURL) else { return 0 }
        try backup(cursorHooksURL)
        var removed = 0

        if var hooks = root["hooks"] as? [String: Any] {
            for (event, value) in hooks {
                guard let entries = value as? [[String: Any]] else { continue }
                let kept = entries.filter { entry in
                    guard let command = entry["command"] as? String else { return true }
                    if isOwned(command) { removed += 1; return false }
                    return true
                }
                hooks[event] = kept.isEmpty ? nil : kept
            }
            root["hooks"] = hooks
        }

        try write(root, to: cursorHooksURL)
        return removed
    }

    private func removeLaunchAgent() -> Bool {
        guard FileManager.default.fileExists(atPath: launchAgentURL.path) else { return false }
        // Best effort: the job may already be unloaded.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())/com.agenthub.daemon"]
        try? process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: launchAgentURL)
        return true
    }

    private func loadObject(_ url: URL) throws -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func backup(_ url: URL) throws {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let destination = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).agenthub-backup-\(stamp)")
        try? FileManager.default.copyItem(at: url, to: destination)
    }

    private func write(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `xcodebuild ... test -only-testing:AgentHubAppTests/LegacyUninstallerTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Run it once against the real machine**

Add to `applicationDidFinishLaunching`, before `menuBar.install()`:

```swift
        // Earlier versions installed a daemon and provider hooks. Removing them
        // once is part of the migration; it is a no-op afterwards.
        if !UserDefaults.standard.bool(forKey: "legacyUninstallCompleted") {
            _ = try? LegacyUninstaller.standard().run()
            UserDefaults.standard.set(true, forKey: "legacyUninstallCompleted")
        }
```

Then launch the app and confirm: `~/.claude/settings.json` keeps `jcode` and
`afplay` but has no AgentHub entries and no `statusLine`; `~/.cursor/hooks.json`
keeps OpenIsland's entries only; `launchctl print gui/$(id -u)/com.agenthub.daemon`
reports the job is gone.

- [ ] **Step 6: Commit**

```bash
git add App/Migration Tests/AgentHubAppTests/LegacyUninstallerTests.swift App/AgentHubApp.swift
git commit -m "feat: remove the legacy daemon and provider hooks on first launch"
```

---

### Task 10: Delete the old codebase

**Files:**
- Delete: the modules and app files listed in File Structure
- Modify: `Package.swift`, `project.yml`, `scripts/check.sh`, `README.md`

- [ ] **Step 1: Delete the sources**

```bash
git rm -r Sources/agenthubd Sources/AgentHubDaemon Sources/AgentHubIPC \
  Sources/AgentHubPersistence Sources/AgentHubCore Sources/AgentHubClaude \
  Sources/AgentHubCursor Sources/AgentHubOpenCode Sources/AgentHubCodex \
  Sources/AgentHubTestSupport Sources/AgentHubSecurity Sources/agenthub-claude-hook \
  Sources/agenthub-claude-statusline Sources/agenthub-cursor-hook
git rm -r Tests/AgentHubCoreTests Tests/AgentHubDaemonTests Tests/AgentHubIPCTests \
  Tests/AgentHubPersistenceTests Tests/AgentHubCodexTests Tests/AgentHubClaudeTests \
  Tests/AgentHubCursorTests Tests/AgentHubOpenCodeTests Tests/AgentHubOpenCodeTestSupport Tests/AgentHubSecurityTests
git rm -r App/Features/Dashboard App/Features/Sessions App/Features/Requests \
  App/Features/Health App/Features/Claude App/Features/OpenCode App/Features/Cursor \
  App/Features/Quota
git rm App/DaemonClient.swift App/DaemonInstallation.swift App/AppEnvironment.swift \
  App/JumpOpener.swift App/AXClaudeAccessibilitySurface.swift \
  App/ClaudeNativeInteractionExecutor.swift
git rm Support/install-daemon.sh Support/uninstall-daemon.sh Support/com.agenthub.daemon.plist
git rm -r Tests/Fixtures/Claude Tests/Fixtures/Cursor Tests/Fixtures/OpenCode
```

Keep `Tests/Fixtures/Codex/rate-limits-live.jsonl` — Task 2's decoder test uses
that shape.

- [ ] **Step 2: Reduce Package.swift**

Replace the whole file with:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentHub",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentHubQuota", targets: ["AgentHubQuota"]),
    ],
    targets: [
        .target(
            name: "AgentHubQuota",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(name: "AgentHubQuotaTests", dependencies: ["AgentHubQuota"]),
    ]
)
```

GRDB and swift-nio are no longer used; dropping them removes both dependencies.

- [ ] **Step 3: Reduce check.sh**

Replace everything after the `swift test` line with:

```zsh
xcodegen generate
xcodebuild \
  -project AgentHub.xcodeproj \
  -scheme AgentHubApp \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/xcode \
  CODE_SIGNING_ALLOWED=NO \
  test

# A provider token is read for one request and never persisted. These are the
# only files permitted to name one.
if rg -n 'accessToken|WorkosCursorSessionToken' Sources \
  | rg -v '^Sources/AgentHubQuota/ClaudeQuota\.swift:' \
  | rg -v '^Sources/AgentHubQuota/CursorLoginSessionReader\.swift:' \
  | rg -v '^Sources/AgentHubQuota/CursorQuota\.swift:' >/dev/null; then
  print -u2 -- "Provider token literals are confined to their readers"
  exit 1
fi
if rg -n 'accessToken|WorkosCursorSessionToken' App >/dev/null; then
  print -u2 -- "Provider token literals must not appear in the app"
  exit 1
fi

# Usage is read from the providers themselves; never install software to get it.
if rg -n -- 'brew |--cask|sudo ' Sources App >/dev/null; then
  print -u2 -- "AgentHub must never invoke a package manager or sudo"
  exit 1
fi
```

Delete the embedded-helper checks, the Claude launch-argument checks, the
permission-bypass check, and the status-line and hooks ownership checks — every
file they guard is gone.

- [ ] **Step 4: Rewrite the README**

Replace `README.md` with a description of what AgentHub now is: a menu bar
usage panel for Claude, Codex, Cursor, and OpenCode; how to build it
(`xcodegen generate` then `xcodebuild`); that it must be added to Login Items;
and that Cursor usage requires authorising in Settings.

- [ ] **Step 5: Run the full gate**

Run: `zsh scripts/check.sh`
Expected: exit 0, `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: delete sessions, permissions, handoff, and the daemon"
```

---

### Task 11: Live verification

**Files:** none

- [ ] **Step 1: Build and launch**

Run: `zsh scripts/check.sh && open .build/xcode/Build/Products/Debug/AgentHubApp.app`
Expected: gate green; no Dock icon; a menu bar icon appears.

- [ ] **Step 2: Check every provider reports**

Hover the icon. Expected: four sections — Claude (`5h`, `7d`), Codex (`7d`),
Cursor (`31d · API`, `31d · Auto`, `31d · Total`), OpenCode (`5h`, `7d`, `30d`) —
with percentages set large, ordered the same on every refresh.

Compare Claude's figure against:

```bash
TOK=$(security find-generic-password -s "Claude Code-credentials" -w | python3 -c "import json,sys;print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])")
curl -s -H "Authorization: Bearer $TOK" -H "anthropic-beta: oauth-2025-04-20" https://api.anthropic.com/api/oauth/usage | python3 -m json.tool | head -12
```

Expected: the panel matches `five_hour` and `seven_day`.

- [ ] **Step 3: Check the interactions**

Expected: sweeping the pointer across the menu bar does not open the panel;
resting on the icon opens it after ~0.3s; moving away closes it; clicking pins
it; ⌥⌘U opens it pinned; the refresh button updates `resets` times.

- [ ] **Step 4: Confirm the machine is clean**

```bash
python3 -c "
import json,os
d=json.load(open(os.path.expanduser('~/.claude/settings.json')))
print('claude hook events:', list(d.get('hooks',{}).keys()))
print('statusLine present:', 'statusLine' in d)
"
python3 -c "
import json,os
d=json.load(open(os.path.expanduser('~/.cursor/hooks.json')))
print('cursor agenthub entries:', sum(1 for v in d.get('hooks',{}).values() for e in v if 'agenthub' in str(e.get('command',''))))
"
launchctl print "gui/$(id -u)/com.agenthub.daemon" 2>&1 | head -2
```

Expected: no AgentHub hooks in either file, the user's own entries intact, no
`statusLine`, and launchctl reporting the job does not exist.

- [ ] **Step 5: Commit any fixes**

```bash
git add -A
git commit -m "fix: address issues found in live verification"
```

---

## Self-Review

**Spec coverage.** Section 3 architecture → Tasks 1–3, 10. Section 4 quota
sources → Task 2, with the credential rule enforced by Task 10's check.sh and
the refresh rules by Task 3. Section 5 interaction → Tasks 5, 7, 8. Section 6
visual design → Tasks 4, 6. Section 7 consequences → Task 9 (hooks, LaunchAgent)
and Task 10's README (Login Items). Section 8 testing → the test steps
throughout, plus Task 11.

**Type consistency.** `QuotaWindow`, `Provider`, `QuotaPresentation`, and
`QuotaProviderRow` keep the names and signatures they have today.
`QuotaService.windows(force:)` matches the `OpenCodeGoQuotaCache.windows(force:)`
pattern being replaced. `Cancellable` is defined in Task 5 and used by Task 7.
`HotKeyBinding` is defined in Task 8 and used only there.

**Known gap, deliberately left.** Task 8 renders the hotkey but does not let the
user record a new one; `HotKeyBinding.save` exists and is tested, so the binding
is configurable through defaults but not yet through the UI. A recorder control
is worth its own task once the panel is in daily use.
