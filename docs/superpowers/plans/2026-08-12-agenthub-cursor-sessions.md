# AgentHub Cursor Sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Discover local Cursor IDE Agent Chat sessions through user-level hooks, resolve selected tool permissions synchronously from AgentHub, jump/handoff safely, and show Cursor subscription usage after explicit local-login authorization.

**Architecture:** A new `AgentHubCursor` adapter ingests Cursor hook envelopes over the existing Unix socket. Decision hooks (`beforeShellExecution`, `beforeMCPExecution`) create pending requests and block in `agenthub-cursor-hook` until AgentHub resolves them or a timeout returns Cursor-native `ask`. There is no managed Cursor runtime. Quota uses an opt-in collector that reads the local Cursor login session into process memory only and maps dashboard usage into `QuotaWindow`.

**Tech Stack:** Swift 6, Swift concurrency, XCTest, SwiftNIO Unix IPC, SQLite/GRDB, Cursor IDE hooks (`~/.cursor/hooks.json`), URLSession for usage API, AppKit/`open`/`cursor` CLI for jump.

## Global Constraints

- Target macOS 14+ and Swift 6 strict concurrency.
- Validate against the Cursor hooks contract at https://cursor.com/docs/hooks; tolerate additive JSON fields.
- Default `scripts/check.sh` / `swift test` must not modify real `~/.cursor/hooks.json`, read real Cursor auth, call live usage APIs, launch Cursor UI automation, or submit prompts.
- Never default-allow a tool permission; timeout and errors return `ask`.
- Never persist Cursor access tokens in SQLite, Keychain, logs, or IPC snapshots.
- Preserve OpenIsland and other existing user hooks; uninstall only AgentHub-owned absolute helper paths.
- No managed Cursor launch; handoffs to Cursor are clipboard-and-jump only.
- Store no raw hook archives, full prompts, or full shell/MCP inputs — bounded previews only.
- Preserve three-turn / 256 KiB / 24-hour preview limits and 20-turn handoff limit.
- Every task: RED → verify RED → GREEN → verify GREEN → commit.
- Work on a feature branch / worktree from local `main`; do not force-push.

---

## File Map

### New package files

- `Sources/AgentHubIPC/DaemonSocketPath.swift`: shared `AGENTHUB_SOCKET` override + Application Support socket resolution (replaces Claude-only helper socket).
- `Sources/AgentHubCursor/CursorHookModels.swift`: Cursor hook event vocabulary and bounded decoders.
- `Sources/AgentHubCursor/CursorHookInstaller.swift`: merge/uninstall for `~/.cursor/hooks.json`.
- `Sources/AgentHubCursor/CursorHookReporter.swift`: observe-only delivery helper.
- `Sources/AgentHubCursor/CursorPermissionGate.swift`: maps decisions ↔ Cursor stdout JSON; wait budget constant.
- `Sources/AgentHubCursor/CursorAdapter.swift`: sessions, nodes, requests, jump, configure, ingest.
- `Sources/AgentHubCursor/CursorQuotaAuthStore.swift`: authorized flag only (UserDefaults or SQLite component — **no token storage**).
- `Sources/AgentHubCursor/CursorLoginSessionReader.swift`: reads local Cursor login material into memory.
- `Sources/AgentHubCursor/CursorQuotaClient.swift`: HTTP client for pinned usage endpoints (injectable URLProtocol/session).
- `Sources/AgentHubCursor/CursorQuotaCollector.swift`: polling, mapping to `QuotaWindow`, revoke clears windows.
- `Sources/AgentHubCursor/Bootstrap.swift`: module marker.
- `Sources/agenthub-cursor-hook/main.swift`: one-shot hook bridge with sync permission wait.

### New app / tests / fixtures / docs

- `App/Features/Cursor/CursorSettingsView.swift`: hooks + quota authorize/revoke UI.
- `Tests/AgentHubCursorTests/*.swift`: models, installer, permission gate, adapter, quota.
- `Tests/AgentHubDaemonTests/CursorVerticalSliceTests.swift`: socket path including await-permission.
- `Tests/AgentHubIPCTests/CursorHookDeliveryTests.swift`: optional live-shaped delivery with `AGENTHUB_SOCKET`.
- `Tests/Fixtures/Cursor/*.json`: hook and usage fixtures.
- `docs/cursor-testing.md`: boundaries and opt-in flags.

### Existing files modified

- `Package.swift`: `AgentHubCursor` library, `agenthub-cursor-hook` executable, tests.
- `Sources/AgentHubCore/Models.swift`: `ProviderConfigurationAction` authorize/revoke cases; `HookPermissionDecision` if kept in Core.
- `Sources/AgentHubIPC/Messages.swift`: `awaitHookPermission` command + reply (protocol stays v3 if additive Codable cases remain backward compatible for same-version app/daemon; bump only if required by existing decoder tests).
- `Sources/AgentHubDaemon/DaemonAPI.swift`, `Coordinator.swift`, `RequestService.swift`: wire await + Cursor adapter.
- `Sources/agenthubd/main.swift`: construct `CursorAdapter` + quota collector.
- `Sources/AgentHubClaude/ClaudeHelperSocket.swift`: thin wrapper or deletion after move to `DaemonSocketPath`.
- `App/DaemonInstallation.swift`, `project.yml`: stage `agenthub-cursor-hook`.
- `App/Features/Dashboard/*`: Cursor settings entry; no primary “New Cursor session”.
- `App/JumpOpener.swift` (or equivalent): open Cursor / workspace.
- `scripts/check.sh`, `README.md`, `docs/development.md`: Cursor gates and ops notes.

---

### Task 1: Shared daemon socket path + configuration actions

**Files:**
- Create: `Sources/AgentHubIPC/DaemonSocketPath.swift`
- Modify: `Sources/AgentHubClaude/ClaudeHelperSocket.swift`
- Modify: `Sources/AgentHubCore/Models.swift` (`ProviderConfigurationAction`)
- Modify: `Sources/AgentHubIPC/Messages.swift`
- Test: `Tests/AgentHubIPCTests/IPCTests.swift` (or new `DaemonSocketPathTests.swift`)
- Test: `Tests/AgentHubCoreTests/ModelTests.swift`

**Interfaces:**
- Produces: `DaemonSocketPath.overrideVariable == "AGENTHUB_SOCKET"`, `DaemonSocketPath.resolve(environment:fileManager:) throws -> String`
- Produces: `ProviderConfigurationAction.authorizeQuotaAccess`, `.revokeQuotaAccess`
- Produces: `HookPermissionDecision: String, Codable { case allow, deny, ask }`
- Produces: `DaemonCommand.awaitHookPermission(requestID: UUID, timeoutMilliseconds: Int)`
- Produces: `DaemonReply.hookPermission(HookPermissionDecision)`

- [ ] **Step 1: Write failing tests**

```swift
func testDaemonSocketPathHonorsAgentHubSocketOverride() throws {
    let path = try DaemonSocketPath.resolve(
        environment: ["AGENTHUB_SOCKET": "/tmp/agenthub-test.sock"]
    )
    XCTAssertEqual(path, "/tmp/agenthub-test.sock")
}

func testAwaitHookPermissionCommandRoundTrips() throws {
    let id = UUID()
    let command = DaemonCommand.awaitHookPermission(
        requestID: id,
        timeoutMilliseconds: 25_000
    )
    let data = try JSONEncoder.agentHub.encode(IPCEnvelope(body: command))
    let decoded = try JSONDecoder.agentHub.decode(
        IPCEnvelope<DaemonCommand>.self,
        from: data
    )
    guard case .awaitHookPermission(id, 25_000) = decoded.body else {
        return XCTFail("awaitHookPermission did not round trip")
    }
}

func testAuthorizeQuotaAccessIsDistinctFromInstallQuotaReporter() {
    XCTAssertNotEqual(
        ProviderConfigurationAction.authorizeQuotaAccess,
        .installQuotaReporter
    )
    XCTAssertNotEqual(
        ProviderConfigurationAction.revokeQuotaAccess,
        .uninstallQuotaReporter
    )
}
```

- [ ] **Step 2: Run tests — expect RED**

Run: `swift test --filter 'DaemonSocketPath|AwaitHookPermission|AuthorizeQuota'`

Expected: fail/compile error for missing types.

- [ ] **Step 3: Implement minimal types**

```swift
// DaemonSocketPath.swift — same resolution rules as current ClaudeHelperSocket
public enum DaemonSocketPath {
    public static let overrideVariable = "AGENTHUB_SOCKET"
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> String { /* override or Application Support/.../agenthub.sock */ }
}

public enum HookPermissionDecision: String, Codable, Sendable {
    case allow, deny, ask
}

// ProviderConfigurationAction — add:
case authorizeQuotaAccess, revokeQuotaAccess

// DaemonCommand — add:
case awaitHookPermission(requestID: UUID, timeoutMilliseconds: Int)

// DaemonReply — add:
case hookPermission(HookPermissionDecision)
```

Update `ClaudeHelperSocket.resolve` to call `DaemonSocketPath.resolve`.
Update every `DaemonCommand`/`DaemonReply` switch (`DaemonAPI`, `AppEnvironment`, IPC tests) so the build stays exhaustive.

- [ ] **Step 4: Run tests — expect GREEN**

Run: `swift test --filter 'DaemonSocketPath|AwaitHookPermission|AuthorizeQuota|IPCTests'`

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentHubIPC/DaemonSocketPath.swift \
  Sources/AgentHubClaude/ClaudeHelperSocket.swift \
  Sources/AgentHubCore/Models.swift \
  Sources/AgentHubIPC/Messages.swift \
  Sources/AgentHubDaemon/DaemonAPI.swift \
  App/AppEnvironment.swift \
  Tests/
git commit -m "feat: add Cursor hook permission IPC and quota auth actions"
```

---

### Task 2: Cursor hook models

**Files:**
- Create: `Sources/AgentHubCursor/CursorHookModels.swift`
- Create: `Sources/AgentHubCursor/Bootstrap.swift`
- Create: `Tests/Fixtures/Cursor/session-start.json`
- Create: `Tests/Fixtures/Cursor/before-shell-execution.json`
- Create: `Tests/Fixtures/Cursor/before-mcp-execution.json`
- Create: `Tests/Fixtures/Cursor/subagent-start.json`
- Create: `Tests/Fixtures/Cursor/stop.json`
- Test: `Tests/AgentHubCursorTests/CursorHookModelsTests.swift`
- Modify: `Package.swift`

**Interfaces:**
- Produces: `enum CursorHookEventName: String` with at least `sessionStart`, `sessionEnd`, `beforeSubmitPrompt`, `stop`, `beforeShellExecution`, `afterShellExecution`, `beforeMCPExecution`, `afterMCPExecution`, `subagentStart`, `subagentStop`, `afterAgentResponse`, `afterAgentThought`, `preCompact`, `unknown`
- Produces: `struct CursorHookPayload` with `event`, `conversationID`, `generationID`, `sessionID`, `workspaceRoots`, `boundedPreview`, `requiresPermissionDecision: Bool`
- Produces: `enum CursorHookDecoder` / `func decode(_ data: Data) throws -> CursorHookPayload`
- Decision events: `beforeShellExecution`, `beforeMCPExecution` set `requiresPermissionDecision == true`

- [ ] **Step 1: Add fixtures and failing decoder tests**

Fixture `before-shell-execution.json` must include `hook_event_name` / Cursor equivalent fields plus `conversation_id`, `generation_id`, `command`, `cwd` as documented. Decoder must accept either Cursor-native names or documented aliases and ignore unknown keys.

```swift
func testBeforeShellExecutionRequiresPermissionDecision() throws {
    let data = try fixture("before-shell-execution")
    let payload = try CursorHookDecoder().decode(data)
    XCTAssertEqual(payload.event, .beforeShellExecution)
    XCTAssertTrue(payload.requiresPermissionDecision)
    XCTAssertFalse(payload.conversationID.isEmpty)
    XCTAssertLessThanOrEqual(payload.boundedPreview.utf8.count, 2_048)
}

func testUnknownEventDoesNotThrow() throws {
    let data = Data(#"{"hook_event_name":"totally_new","conversation_id":"c1"}"#.utf8)
    let payload = try CursorHookDecoder().decode(data)
    XCTAssertEqual(payload.event, .unknown)
    XCTAssertFalse(payload.requiresPermissionDecision)
}
```

- [ ] **Step 2: RED** — `swift test --filter CursorHookModelsTests`

- [ ] **Step 3: Implement decoder + Package.swift target `AgentHubCursor`**

Bounded preview rules: for shell, take at most 2 KiB of `command`; for MCP, tool name + truncated input summary; never store full stdin beyond decode ephemeral.

- [ ] **Step 4: GREEN** — `swift test --filter CursorHookModelsTests`

- [ ] **Step 5: Commit** — `feat: decode Cursor hook payloads`

---

### Task 3: Cursor hooks.json installer

**Files:**
- Create: `Sources/AgentHubCursor/CursorHookInstaller.swift`
- Test: `Tests/AgentHubCursorTests/CursorHookInstallerTests.swift`

**Interfaces:**
- Produces: `struct CursorHookInstaller` with `init(hooksURL:executableURL:)`, `install() throws`, `uninstall() throws`, `status() throws -> ProviderComponentStatus`
- Observed decision+lifecycle events written (exact list matching Task 2 decision + lifecycle set used by adapter)
- Ownership: command string equals normalized absolute helper path

- [ ] **Step 1: Failing tests with OpenIsland-shaped fixture**

```swift
func testInstallMergesBesideExistingOpenIslandHooks() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let hooksURL = dir.appendingPathComponent("hooks.json")
    let existing = """
    {"version":1,"hooks":{"beforeSubmitPrompt":[{"command":"/tmp/OpenIslandHooks --source cursor"}],"stop":[{"command":"/tmp/OpenIslandHooks --source cursor"}]}}
    """
    try Data(existing.utf8).write(to: hooksURL)
    let helper = dir.appendingPathComponent("agenthub-cursor-hook")
    try Data().write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

    let installer = CursorHookInstaller(hooksURL: hooksURL, executableURL: helper)
    try installer.install()

    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as! [String: Any]
    let hooks = json["hooks"] as! [String: Any]
    let prompt = hooks["beforeSubmitPrompt"] as! [[String: Any]]
    XCTAssertEqual(prompt.count, 2)
    XCTAssertTrue(prompt.contains { ($0["command"] as? String) == helper.path })
    XCTAssertTrue(prompt.contains { ($0["command"] as? String)?.contains("OpenIsland") == true })
}

func testUninstallRemovesOnlyAgentHubCommands() throws {
    // install then uninstall; OpenIsland commands remain; AgentHub path gone
}
```

- [ ] **Step 2: RED**

- [ ] **Step 3: Implement merge/uninstall** (atomic replace via temp file in same directory; mode `0600` on hooks file if creating)

For security-sensitive events (`beforeShellExecution`, `beforeMCPExecution`), set `"failClosed": true` **only on AgentHub’s own hook object**, not on neighbors.

- [ ] **Step 4: GREEN**

- [ ] **Step 5: Commit** — `feat: install Cursor hooks without clobbering peers`

---

### Task 4: Permission gate + await wiring in RequestService

**Files:**
- Create: `Sources/AgentHubCursor/CursorPermissionGate.swift`
- Modify: `Sources/AgentHubDaemon/RequestService.swift`
- Modify: `Sources/AgentHubDaemon/DaemonAPI.swift`
- Modify: `Sources/AgentHubDaemon/Coordinator.swift` (if needed to expose waiter)
- Test: `Tests/AgentHubCursorTests/CursorPermissionGateTests.swift`
- Test: `Tests/AgentHubDaemonTests/CursorPermissionAwaitTests.swift`

**Interfaces:**
- Produces: `CursorPermissionGate.defaultTimeoutMilliseconds = 25_000`
- Produces: `CursorPermissionGate.responseJSON(for: HookPermissionDecision) -> Data` → `{"permission":"allow|deny|ask"}`
- Produces: RequestService method `func awaitHookPermission(requestID: UUID, timeoutMilliseconds: Int) async -> HookPermissionDecision` that:
  - returns `.ask` on timeout
  - returns mapped decision when `resolveRequest` completes for that id
  - returns `.ask` if request missing/expired/fingerprint invalid
- Never maps “no decision” to `.allow`

- [ ] **Step 1: Failing unit tests**

```swift
func testPermissionGateNeverSerializesDefaultAllowOnUnknown() {
    let data = CursorPermissionGate.responseJSON(for: .ask)
    let obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    XCTAssertEqual(obj["permission"] as? String, "ask")
}

func testAwaitHookPermissionTimesOutToAsk() async {
    let decision = await service.awaitHookPermission(
        requestID: UUID(),
        timeoutMilliseconds: 50
    )
    XCTAssertEqual(decision, .ask)
}
```

- [ ] **Step 2: RED**

- [ ] **Step 3: Implement waiter**

Use an actor-local continuation map keyed by request ID. `resolve` resumes the continuation with allow/deny derived from `RequestDecision`. Do **not** `await withCheckedContinuation` inside an actor method that must also be called to resume — follow the Claude note: keep resume on a separate path / poll with `Task.sleep` if needed to avoid deadlock.

Wire `DaemonAPI` case `.awaitHookPermission` → `.hookPermission(...)`.

- [ ] **Step 4: GREEN**

- [ ] **Step 5: Commit** — `feat: await Cursor hook permission decisions`

---

### Task 5: CursorAdapter ingest, sessions, jump (no launch)

**Files:**
- Create: `Sources/AgentHubCursor/CursorAdapter.swift`
- Test: `Tests/AgentHubCursorTests/CursorAdapterTests.swift`
- Test: `Tests/AgentHubCursorTests/CursorAdapterConfigurationTests.swift`

**Interfaces:**
- Produces: `actor CursorAdapter: AgentAdapter, HookEventIngestingAdapter, ProviderConfigurableAdapter`
- `launch` throws `CursorAdapterError.unsupportedCapability` (or returns failure via adapter error type)
- `jumpTarget(for:)` → `.application(bundleID: "com.todesktop.*" /* use real Cursor bundle id discovered on machine */)` or workspace open hint type already used by JumpTarget — match existing enum cases exactly
- `ingest`: create/update session by `conversation_id`; decision events create `PendingRequest` with fingerprint; observe events update status/nodes
- `configure(.installHooks/.uninstallHooks/.refreshComponents/.authorizeQuotaAccess/.revokeQuotaAccess)`

- [ ] **Step 1: Failing adapter tests**

```swift
func testSessionStartCreatesIdeSessionKeyedByConversationID() async throws {
    let adapter = CursorAdapter(accountID: "default", hookInstaller: nil, quotaCollector: nil)
    try await adapter.ingest(envelope(fixture: "session-start"))
    let snap = await adapter.reconcile()
    XCTAssertEqual(snap.sessions.count, 1)
    XCTAssertEqual(snap.sessions.first?.nativeID, "conv-fixture-1")
}

func testBeforeShellExecutionCreatesPendingPermissionRequest() async throws {
    let adapter = CursorAdapter(...)
    try await adapter.ingest(envelope(fixture: "session-start"))
    try await adapter.ingest(envelope(fixture: "before-shell-execution"))
    let snap = await adapter.reconcile()
    XCTAssertEqual(snap.requests.count, 1)
    XCTAssertEqual(snap.requests.first?.kind /* permission-ish */, ...)
}

func testLaunchIsUnsupported() async {
    await XCTAssertThrowsError(try await adapter.launch(LaunchRequest(...)))
}
```

Note: bind actor results to locals before `XCTAssert` (Swift 6 autoclosure rule).

- [ ] **Step 2: RED**

- [ ] **Step 3: Implement adapter**

Fingerprint = hash/truncate of `conversation_id + generation_id + event + boundedPreview`. On `resolve`, re-check fingerprint; mismatch → surface failure so awaiter gets `.ask`.

Jump: prefer recorded `workspaceRoots.first` if present; else activate Cursor app only.

- [ ] **Step 4: GREEN**

- [ ] **Step 5: Commit** — `feat: normalize Cursor IDE sessions from hooks`

---

### Task 6: agenthub-cursor-hook executable

**Files:**
- Create: `Sources/agenthub-cursor-hook/main.swift`
- Create: `Sources/AgentHubCursor/CursorHookReporter.swift`
- Modify: `Package.swift`
- Test: `Tests/AgentHubCursorTests/CursorHookReporterTests.swift`
- Test: `Tests/AgentHubIPCTests/CursorHookDeliveryTests.swift` (socket delivery with override)

**Interfaces:**
- Observe path: ingest + exit 0, stdout `{}` or event-appropriate empty continue
- Decision path: ingest → read accepted request id from adapter via reply change:
  - **Required IPC tweak:** change decision ingest to return `.accepted(requestID)` when a pending permission request was created; observe events keep `.completed`
  - Or encode request id in a new reply `.hookAccepted(UUID)`
- Then `awaitHookPermission` → print permission JSON → exit 0
- Daemon down / errors → print `ask` JSON for decision events; exit 0 (do not fail Cursor closed unless failClosed and crash — avoid crashing)

- [ ] **Step 1: Failing reporter tests** with fake send closures

```swift
func testDecisionPathReturnsAskWhenSendFails() async throws {
    let reporter = CursorHookReporter(
        send: { _ in throw URLError(.cannotConnectToHost) },
        awaitPermission: { _, _ in .ask }
    )
    let out = try await reporter.handle(stdin: fixtureData("before-shell-execution"), sourcePID: 1)
    let obj = try JSONSerialization.jsonObject(with: out.stdout) as! [String: Any]
    XCTAssertEqual(obj["permission"] as? String, "ask")
}
```

- [ ] **Step 2: RED**

- [ ] **Step 3: Implement main + reporter; if ingest must return request id, update `DaemonAPI` + Coordinator.ingest return value for Cursor decision events**

Document the chosen reply shape in this commit message body.

- [ ] **Step 4: GREEN** including `AGENTHUB_SOCKET` delivery test against throwaway server when feasible

- [ ] **Step 5: Commit** — `feat: package Cursor hook bridge with sync permissions`

---

### Task 7: Daemon install embedding + agenthubd registration + UI settings

**Files:**
- Modify: `App/DaemonInstallation.swift` — add `cursorHookExecutable`, stage beside other helpers
- Modify: `project.yml`, Xcode embed phases as Claude hook was embedded
- Modify: `Sources/agenthubd/main.swift` — `resolvedCursorHookInstaller()`, register adapter
- Create: `App/Features/Cursor/CursorSettingsView.swift`
- Modify: `App/Features/Dashboard/DashboardView.swift`, `DashboardViewModel.swift`
- Modify: jump opener for Cursor workspace
- Test: `Tests/AgentHubAppTests/DaemonInstallationTests.swift`
- Test: `Tests/AgentHubAppTests/DashboardViewModelTests.swift`

**Interfaces:**
- Installer stages four helpers if statusline already present: `agenthubd`, Claude hook, Claude statusline, Cursor hook — validate all required present before copy (extend `stageHelpers` carefully without breaking Claude-only installs: Cursor hook required once product ships Cursor)
- Settings: Install/Remove Hooks; Authorize/Revoke Usage; component rows `hooks` and `quota`
- No primary launch button for Cursor

- [ ] **Step 1: Failing install + view-model tests** (Cursor hook path appears; configure actions sent)

- [ ] **Step 2: RED**

- [ ] **Step 3: Implement embedding + UI + daemon wiring**

Resolve Cursor bundle identifier on a real Mac (`osascript`/`mdls` or `com.todesktop.230313mzl4w4u92` historically — **verify live** and put the verified id in code comments + constant).

- [ ] **Step 4: GREEN** + `zsh scripts/check.sh` still passes static gates (extend gates in Task 10 if needed)

- [ ] **Step 5: Commit** — `feat: expose Cursor controls and embed hook helper`

---

### Task 8: Vertical slice — hooks to inbox to await to reply

**Files:**
- Create: `Tests/AgentHubDaemonTests/CursorVerticalSliceTests.swift`
- Modify: handoff tests if Cursor targets participate in clipboard-and-jump only

**Interfaces:**
- End-to-end in-process: bind Unix server → ingest shell hook → snapshot has request → concurrent `awaitHookPermission` → `resolveRequest(.accept)` → await returns `.allow`

- [ ] **Step 1: Write failing vertical slice test**

```swift
func testCursorPermissionRoundTripThroughUnixSocket() async throws {
    // start daemon API + CursorAdapter with temp hooks file
    // client.ingest decision envelope
    // async let decision = client.send(.awaitHookPermission(id, 5_000))
    // client.send(.resolveRequest(id, .accept))
    // assert hookPermission(.allow)
}
```

- [ ] **Step 2: RED**

- [ ] **Step 3: Fix any gaps in Coordinator/RequestService**

- [ ] **Step 4: GREEN**

- [ ] **Step 5: Commit** — `test: verify Cursor permission vertical slice`

---

### Task 9: Quota authorize + collector (explicit auth read)

**Files:**
- Create: `Sources/AgentHubCursor/CursorQuotaAuthStore.swift`
- Create: `Sources/AgentHubCursor/CursorLoginSessionReader.swift`
- Create: `Sources/AgentHubCursor/CursorQuotaClient.swift`
- Create: `Sources/AgentHubCursor/CursorQuotaCollector.swift`
- Create: `Tests/Fixtures/Cursor/usage-period.json`
- Test: `Tests/AgentHubCursorTests/CursorQuotaCollectorTests.swift`
- Test: `Tests/AgentHubCursorTests/CursorQuotaPrivacyTests.swift`

**Interfaces:**
- `CursorQuotaAuthStore.isAuthorized: Bool` persisted (UserDefaults suite `com.agenthub.cursor` or component message) — **boolean only**
- `CursorLoginSessionReader.readAccessToken() throws -> String` reads pinned local path(s); never logs token
- `CursorQuotaClient.fetchWindows(token:) async throws -> [QuotaWindow]`
- `CursorQuotaCollector` polls only when authorized; `revoke` clears windows + unauthorized
- Pin concrete auth artifact path and HTTP endpoints in code after a **live probe step** recorded in `docs/cursor-testing.md` (path + RPC names, no secrets)

- [ ] **Step 1: Live probe (manual, documented)** on the dev machine: locate login storage path without printing secrets; capture anonymized usage JSON shape into `Tests/Fixtures/Cursor/usage-period.json`

- [ ] **Step 2: Failing tests**

```swift
func testCollectorEmitsWindowsFromFixtureClient() async throws {
    let client = FixtureQuotaClient(fixture: "usage-period")
    let collector = CursorQuotaCollector(auth: .authorized, reader: FakeReader(), client: client)
    let windows = try await collector.refresh()
    XCTAssertFalse(windows.isEmpty)
    XCTAssertEqual(windows.first?.source, "cursor-dashboard")
}

func testEncodedSnapshotNeverContainsTokenSubstring() async throws {
    let token = "secret-token-value-xyz"
    // build state after refresh using FakeReader(token)
    let data = try JSONEncoder.agentHub.encode(state)
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(token))
}

func testRevokeClearsWindowsAndDisablesCollection() async throws {
    // authorize → refresh → revoke → windows empty + unauthorized
}
```

- [ ] **Step 3: RED**

- [ ] **Step 4: Implement reader/client/collector; wire `configure(.authorizeQuotaAccess/.revokeQuotaAccess)`; start refresh loop from adapter/daemon only when authorized**

Absent `resetsAt` → omit window (no fabricated reset). Invalid percent → omit window.

- [ ] **Step 5: GREEN**

- [ ] **Step 6: Commit** — `feat: collect Cursor usage after explicit authorization`

---

### Task 10: Docs, README, check.sh gates, privacy acceptance

**Files:**
- Create: `docs/cursor-testing.md`
- Modify: `docs/development.md`, `README.md`
- Modify: `scripts/check.sh`
- Test: `Tests/AgentHubDaemonTests/PrivacyTests.swift` (extend)

**Gates to add (non-vacuous):**
- Forbid writing `"hooks"` into `~/.cursor/hooks.json` outside `CursorHookInstaller` (mirror Claude statusLine gate pattern with path/symbol allowlist).
- Forbid `accessToken` / `WorkosCursorSessionToken` string literals in `App/` persistence paths if applicable; allow only inside `CursorLoginSessionReader`.
- Require `agenthub-cursor-hook` embedded and executable like other helpers.

- [ ] **Step 1: Write docs + failing check.sh deliberate violation then restore** (prove gate non-vacuous)

- [ ] **Step 2: Extend privacy tests**

- [ ] **Step 3: Full gate** — `zsh scripts/check.sh` expect exit 0

- [ ] **Step 4: Commit** — `docs: describe Cursor testing and install boundaries`

---

## Spec coverage checklist

| Spec requirement | Task |
|---|---|
| User-level hooks merge / uninstall | 3, 7 |
| Hook bridge + socket ingest | 6, 1 |
| Sync permission wait / timeout → ask | 4, 5, 6, 8 |
| Session/subagent normalization | 2, 5 |
| No managed launch | 5, 7 |
| Jump activate + workspace hint | 5, 7 |
| Clipboard-and-jump handoff only | 8 (assert route) + existing DeliveryReconciler behavior |
| Explicit quota auth + in-memory token | 9 |
| Revoke clears windows | 9 |
| Default tests safe | 10 + per-task fixtures |
| OpenIsland preserved | 3 |
| Cloud/CLI/Tab out of scope | (no tasks) |

## Placeholder / consistency review

- IPC request-id return on decision ingest is explicitly required in Task 6; implementers must pick `.accepted(UUID)` vs `.hookAccepted(UUID)` and keep Messages/DaemonAPI/AppEnvironment exhaustive.
- Cursor bundle ID must be verified live in Task 7 (no guessed final constant without probe).
- Quota endpoint paths pinned in Task 9 after live probe — fixtures carry the shape.

---

## Execution notes

- Prefer worktree branch `codex/agenthub-cursor` from local `main`.
- Swift 6: no `await` inside `XCTAssert*` autoclosure; no `static let` of non-Sendable formatters.
- Do not reintroduce CodexBar for Cursor.
- User’s real `~/.cursor/hooks.json` stays untouched until an explicit live install step outside the default plan gate.
