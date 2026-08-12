# AgentHub Claude Quota Implementation Plan

> **SUPERSEDED 2026-08-12.** This plan specified CodexBar as the quota source.
> The user chose to collect usage directly instead, so CodexBar was removed and
> replaced by a status-line reporter: Claude Code pipes `rate_limits`
> (`five_hour` / `seven_day`, each with `used_percentage` and `resets_at`) to its
> configured `statusLine` command, which is real reported usage rather than an
> estimate. Tasks 1 and 4 landed largely as written; Tasks 2 and 3 were replaced
> by `ClaudeStatusLineQuota`, `ClaudeStatusLineInstaller`, and the
> `agenthub-claude-statusline` helper. Retained for history — see
> `docs/claude-testing.md` for the implemented behavior.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install and integrate CodexBar as an explicit Claude subscription-usage source, showing fresh windows and excluding stale data from recommendations without affecting Claude session control.

**Architecture:** `CodexBarClaudeQuotaCollector` discovers the signed app helper or PATH CLI, invokes Claude-only JSON with a bounded timeout, and maps each structured window to `QuotaWindow`. `ClaudeAdapter` owns a cancellable refresh loop and emits component/quota events; the desktop exposes an explicit Homebrew installation action and source diagnostics.

**Tech Stack:** Swift 6, XCTest, Process, CodexBar JSON CLI, existing AgentHub adapter/event/state/SwiftUI architecture.

## Global Constraints

- Execute this plan only after `2026-08-12-agenthub-claude-sessions.md` passes its complete gate.
- Never read Claude OAuth tokens, browser cookies, Keychain secrets, or undocumented Anthropic endpoints directly.
- Use only CodexBar machine-readable JSON; never parse its human-readable cards or progress bars.
- Discovery order is the CodexBar app helper, then PATH; missing source is an explicit unavailable component.
- Refresh every five minutes, use a ten-second command timeout, mark data stale after 15 minutes, and back off 1, 2, 4, 8, then 15 minutes after failures.
- Claude CLI, Desktop, and claude.ai share one account quota and must not appear as separate allowance accounts.
- Stale or partial data may remain visible with timestamp but cannot influence recommendations.
- CodexBar installation requires an explicit user action; AgentHub never performs a silent package-manager mutation.
- Default tests use fixtures and fake command runners; they must not contact Claude or CodexBar network sources.

---

## File Map

### New files

- `Sources/AgentHubClaude/CodexBarClaudeQuotaCollector.swift`: discovery, process invocation, JSON mapping, timeout, and source errors.
- `Sources/AgentHubClaude/CodexBarInstaller.swift`: exact Homebrew cask installation behind an explicit setup action.
- `Tests/AgentHubClaudeTests/CodexBarClaudeQuotaCollectorTests.swift`: JSON and source behavior.
- `Tests/AgentHubClaudeTests/CodexBarInstallerTests.swift`: exact executable/arguments and post-install validation.
- `Tests/Fixtures/Claude/codexbar-usage.json`: primary, weekly, and model-specific windows.
- `Tests/Fixtures/Claude/codexbar-partial.json`: valid windows plus a coarse partial failure.

### Existing files modified

- `Sources/AgentHubCore/Models.swift`: optional quota window ID/label and plan label with backward-compatible decoding.
- `Sources/AgentHubClaude/ClaudeAdapter.swift`: quota collector, refresh loop, events, and component setup action.
- `Sources/agenthubd/main.swift`: construct quota collector and installer.
- `App/Features/Claude/ClaudeSettingsView.swift`: CodexBar install/refresh/source state.
- `App/Features/Quota/QuotaStripView.swift`: Claude window and plan labels.
- `App/Features/Dashboard/DashboardViewModel.swift`: explicit install and refresh actions.
- `Tests/AgentHubDaemonTests/ClaudeVerticalSliceTests.swift`: quota isolation from session health.
- `Tests/AgentHubAppTests/DashboardViewModelTests.swift`: install/refresh actions and stale display.
- `README.md`, `docs/development.md`, `docs/claude-testing.md`, and `scripts/check.sh`: installation and verification.

---

### Task 1: Represent multiple named quota windows without collisions

**Files:**
- Modify: `Sources/AgentHubCore/Models.swift`
- Test: `Tests/AgentHubCoreTests/ModelTests.swift`
- Test: `Tests/AgentHubPersistenceTests/StoreTests.swift`

**Interfaces:**
- Extends: `QuotaWindow.init(provider:accountID:windowID:label:plan:usedPercent:windowDuration:resetsAt:fetchedAt:source:)`.
- Preserves decoding of existing rows that lack `windowID`, `label`, or `plan`.
- Changes ID to include `windowID` when present, preventing a five-hour overall and five-hour model window from colliding.

- [ ] **Step 1: Write failing collision and compatibility tests**

```swift
func testNamedQuotaWindowsWithSameDurationHaveDistinctIDs() throws {
    let overall = try QuotaWindow(provider: .claude, accountID: "user@example.com", windowID: "session", label: "Session", plan: "Pro", usedPercent: 10, windowDuration: 18_000, resetsAt: reset, fetchedAt: now, source: "codexbar")
    let sonnet = try QuotaWindow(provider: .claude, accountID: "user@example.com", windowID: "sonnet", label: "Sonnet", plan: "Pro", usedPercent: 20, windowDuration: 18_000, resetsAt: reset, fetchedAt: now, source: "codexbar")
    XCTAssertNotEqual(overall.id, sonnet.id)
}
```

Add a decoder test using the pre-change JSON shape and assert all new optional
fields decode as nil.

- [ ] **Step 2: Run core/persistence tests and verify RED**

Run: `swift test --filter 'ModelTests|StoreTests'`

Expected: initializer labels do not exist or IDs collide.

- [ ] **Step 3: Add optional fields and explicit stable ID calculation**

Keep existing call sites source-compatible by giving the three new arguments nil
defaults. Use synthesized Codable optionals or an explicit decoder that treats
missing keys as nil. Preserve validation for percentage and positive duration.

- [ ] **Step 4: Run core and persistence suites**

Run: `swift test --filter 'AgentHubCoreTests|AgentHubPersistenceTests'`

Expected: all old and new records pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentHubCore/Models.swift Tests/AgentHubCoreTests/ModelTests.swift Tests/AgentHubPersistenceTests/StoreTests.swift
git commit -m "feat: label provider quota windows"
```

---

### Task 2: Parse Claude usage from bounded CodexBar JSON

**Files:**
- Create: `Sources/AgentHubClaude/CodexBarClaudeQuotaCollector.swift`
- Create: `Tests/AgentHubClaudeTests/CodexBarClaudeQuotaCollectorTests.swift`
- Create: `Tests/Fixtures/Claude/codexbar-usage.json`
- Create: `Tests/Fixtures/Claude/codexbar-partial.json`

**Interfaces:**
- Produces: `ClaudeQuotaCollecting.collect() async throws -> ClaudeQuotaSnapshot`.
- Produces: `CodexBarLocation.discover(fileManager:pathEnvironment:)`.
- Maps source JSON `usage.primary`, `secondary`, `tertiary`, identity, and structured detail bars into distinct `QuotaWindow` values.

- [ ] **Step 1: Write failing discovery, parsing, and timeout tests**

```swift
func testAppHelperWinsOverPathAndMapsAllClaudeWindows() async throws {
    let snapshot = try await collector.collect()
    XCTAssertEqual(snapshot.executable.path, "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI")
    XCTAssertEqual(snapshot.windows.compactMap(\.windowID), ["session", "weekly", "sonnet"])
    XCTAssertTrue(snapshot.windows.allSatisfy { $0.accountID == "user@example.com" })
    XCTAssertTrue(snapshot.windows.allSatisfy { $0.plan == "Pro" })
}

func testTimeoutAndAuthenticationErrorsContainNoRawProviderText() async {
    await XCTAssertThrowsErrorAsync(try await timeoutCollector.collect()) { error in
        XCTAssertEqual(error as? ClaudeQuotaError, .timeout)
    }
}
```

Also test PATH fallback, missing binary, unknown fields, valid partial snapshots,
out-of-range values, and source-provided timestamps.

- [ ] **Step 2: Run collector tests and verify RED**

Run: `swift test --filter CodexBarClaudeQuotaCollectorTests`

Expected: collector types are missing.

- [ ] **Step 3: Implement exact machine-readable invocation and mapping**

Invoke:

```text
codexbar usage --provider claude --source auto --format json --json-only --timeout 10
```

Capture stdout only as the snapshot, cap it at 1 MiB, capture stderr only for a
coarse error category, and terminate the child on timeout. Accept additional JSON
keys. Require provider `claude`, a valid account identity, and at least one valid
window for a successful snapshot. Never fall back to text output.

- [ ] **Step 4: Run collector and Claude unit suites**

Run: `swift test --filter AgentHubClaudeTests`

Expected: all fixture-only tests pass without invoking the installed CLI.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentHubClaude/CodexBarClaudeQuotaCollector.swift Tests/AgentHubClaudeTests Tests/Fixtures/Claude
git commit -m "feat: collect Claude quota from CodexBar"
```

---

### Task 3: Refresh quota independently and install CodexBar only on explicit action

**Files:**
- Create: `Sources/AgentHubClaude/CodexBarInstaller.swift`
- Modify: `Sources/AgentHubClaude/ClaudeAdapter.swift`
- Modify: `Sources/agenthubd/main.swift`
- Create: `Tests/AgentHubClaudeTests/CodexBarInstallerTests.swift`
- Create: `Tests/AgentHubClaudeTests/ClaudeQuotaRefreshTests.swift`
- Modify: `Tests/AgentHubDaemonTests/ClaudeVerticalSliceTests.swift`

**Interfaces:**
- Adds provider actions: `.installQuotaHelper` and `.refreshQuota`.
- Produces component name `codexbar` with executable path, version, source health, and coarse message.
- Produces: `ClaudeQuotaRefreshSchedule.failureDelays == [60, 120, 240, 480, 900]` and success interval 300 seconds.

- [ ] **Step 1: Write failing installer, backoff, and isolation tests**

```swift
func testInstallerUsesExactHomebrewCaskCommandThenValidatesJSON() async throws {
    try await installer.install()
    XCTAssertEqual(await runner.calls().first, .init(executable: "/opt/homebrew/bin/brew", arguments: ["install", "--cask", "codexbar"]))
    XCTAssertTrue(await validator.wasCalled())
}

func testQuotaFailureDoesNotDisconnectClaudeSessions() async throws {
    try await adapter.startQuotaRefresh()
    await quotaCollector.fail(.authenticationRequired)
    let snapshot = try await adapter.reconcile()
    XCTAssertEqual(snapshot.sessions.single?.status, .idle)
    XCTAssertFalse(snapshot.quotas.contains { !$0.isStale(now: clock.now) })
}
```

- [ ] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter 'CodexBarInstallerTests|ClaudeQuotaRefreshTests|ClaudeVerticalSliceTests'`

Expected: missing setup actions/refresh loop or session health is coupled to quota failure.

- [ ] **Step 3: Implement explicit install and cancellable refresh actor state**

Resolve Homebrew only from `/opt/homebrew/bin/brew`, `/usr/local/bin/brew`, or a
validated PATH entry owned by the current user/root. Run exact arguments only
after `.installQuotaHelper`; after success, discover the helper, run `--version`,
and validate a Claude JSON snapshot. Never request sudo or accept a shell string.

Start one refresh task from `eventStream`, cancel it on adapter shutdown, emit
fresh `quotaUpserted` events, and emit only the `codexbar` component degradation
on failure. Keep the last windows so their standard 15-minute staleness can be
shown. Reset backoff after one valid snapshot.

- [ ] **Step 4: Run Claude and daemon suites**

Run: `swift test --filter 'AgentHubClaudeTests|AgentHubDaemonTests'`

Expected: quota updates flow through state and quota failures leave session/request behavior green.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentHubClaude/CodexBarInstaller.swift Sources/AgentHubClaude/ClaudeAdapter.swift Sources/agenthubd/main.swift Tests/AgentHubClaudeTests Tests/AgentHubDaemonTests/ClaudeVerticalSliceTests.swift
git commit -m "feat: refresh Claude quota independently"
```

---

### Task 4: Expose Claude quota setup, labels, freshness, and full verification

**Files:**
- Modify: `App/Features/Claude/ClaudeSettingsView.swift`
- Modify: `App/Features/Quota/QuotaStripView.swift`
- Modify: `App/Features/Dashboard/DashboardViewModel.swift`
- Modify: `Tests/AgentHubAppTests/DashboardViewModelTests.swift`
- Modify: `README.md`
- Modify: `docs/development.md`
- Modify: `docs/claude-testing.md`
- Modify: `scripts/check.sh`

**Interfaces:**
- Adds view-model methods: `installCodexBar()` and `refreshClaudeQuota()`.
- Displays quota label, plan, account, usage, reset time, source, and stale state.

- [ ] **Step 1: Write failing app tests for explicit setup and stale presentation**

```swift
func testInstallCodexBarRequiresExplicitViewModelAction() async {
    await model.installCodexBar()
    XCTAssertEqual(client.commands, [.configureProvider(.claude, .installQuotaHelper)])
}

func testClaudeQuotaPresentationUsesWindowAndPlanLabels() throws {
    let item = QuotaPresentation(window: claudeWeeklyWindow, now: now)
    XCTAssertEqual(item.title, "Claude · Weekly")
    XCTAssertEqual(item.accountPlan, "user@example.com · Pro")
    XCTAssertTrue(item.isStale)
}
```

- [ ] **Step 2: Run app/full tests and verify RED**

Run: `xcodegen generate && xcodebuild -project AgentHub.xcodeproj -scheme AgentHubApp -destination 'platform=macOS' -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO test`

Expected: missing setup action and presentation labels.

- [ ] **Step 3: Implement setup controls and documented source behavior**

Show `Install CodexBar` only when unavailable, `Refresh` when installed, and the
resolved path/version/source message in Claude settings. The quota strip uses the
window label and plan, marks data stale after 15 minutes, and never displays a
fabricated percentage when the collector has no valid window. Document official
Homebrew/manual installation, prompt-free background limitations, and how to
repair authentication in a user-initiated foreground flow.

- [ ] **Step 4: Run final full verification**

Run: `zsh scripts/check.sh`

Expected: all package tests, app tests, packaging checks, static privacy gates, Claude session tests, and Claude quota fixture tests exit 0.

- [ ] **Step 5: Commit**

```bash
git add App README.md docs scripts/check.sh Tests/AgentHubAppTests
git commit -m "test: verify Claude quota integration"
```

---

## Phase B Acceptance Checklist

- [ ] Missing CodexBar never affects Claude sessions, requests, jumps, or handoffs.
- [ ] Installation occurs only after the explicit setup action and uses exact non-shell Homebrew arguments.
- [ ] Claude JSON source displays session, weekly, and model-specific windows without ID collisions.
- [ ] Claude CLI/Desktop/claude.ai are represented by one account allowance.
- [ ] Fifteen-minute stale data remains visible but is excluded from recommendations.
- [ ] Source errors expose only coarse categories and no credentials/provider response body.
- [ ] Default tests make no provider network calls and consume no quota.
- [ ] `zsh scripts/check.sh` exits 0 after both plans.
