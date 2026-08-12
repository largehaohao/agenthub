# AgentHub Claude Sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add visible managed Claude Code CLI sessions plus discovered external CLI and Claude Desktop sessions, with lifecycle hooks, subagents, requests, safe navigation, and bounded cross-agent handoffs.

**Architecture:** A new `AgentHubClaude` adapter consumes provider hook envelopes arriving over the existing user-private Unix socket. AgentHub-managed Claude sessions run in tmux and are attached to iTerm; external terminal and Desktop sessions are observed through the same hook contract and use app-side native interaction plans only when the exact UI can be verified.

**Tech Stack:** Swift 6, Swift concurrency, XCTest, SwiftNIO Unix IPC, tmux, iTerm AppleScript, AppKit Accessibility APIs, SQLite/GRDB, Claude Code hooks.

## Global Constraints

- Target macOS 14 or newer and Swift 6 strict concurrency.
- Validate behavior against Claude Code 2.1.228; tolerate additive hook and transcript fields.
- The default test gate must not send a model prompt, consume Claude quota, inspect real user transcripts, alter real Claude settings, launch iTerm, or request Accessibility.
- Never enable `--dangerously-skip-permissions` or an automatic approval policy.
- Hook commands must use the packaged helper's absolute path and exit quickly when the daemon is unavailable.
- Store no Claude credentials, environment dumps, raw hook archives, or complete transcripts.
- Preserve the existing three-turn/256 KiB/24-hour preview limits and 20-turn handoff limit.
- Direct input is allowed only for a verified managed tmux session; unmanaged CLI and Desktop handoffs remain clipboard-and-jump.
- Every implementation task follows RED → verify RED → GREEN → verify GREEN → commit.

---

## File Map

### New package files

- `Sources/AgentHubClaude/ClaudeHookModels.swift`: bounded Claude hook decoding and provider event vocabulary.
- `Sources/AgentHubClaude/ClaudeHookInstaller.swift`: idempotent user settings merge and precise uninstall.
- `Sources/AgentHubClaude/ClaudeProcessClassifier.swift`: current-user process ancestry and CLI/Desktop surface classification.
- `Sources/AgentHubClaude/ClaudeTerminalRuntime.swift`: tmux lifecycle, literal paste, pane capture, and iTerm attachment.
- `Sources/AgentHubClaude/ClaudeTerminalScreen.swift`: idle/request screen parsing and prompt fingerprints.
- `Sources/AgentHubClaude/ClaudeTranscriptReader.swift`: constrained, bounded Claude JSONL reads.
- `Sources/AgentHubClaude/ClaudeAdapter.swift`: normalized sessions, nodes, requests, routes, launch, send, resolve, and jump.
- `Sources/AgentHubClaude/Bootstrap.swift`: module bootstrap marker.
- `Sources/agenthub-claude-hook/main.swift`: thin one-shot hook executable.
- `Sources/AgentHubDaemon/DeliveryReconciler.swift`: releases queued handoffs after a target becomes idle.
- `App/Features/Claude/ClaudeSettingsView.swift`: hook/runtime/Accessibility health and setup controls.
- `App/ClaudeNativeInteractionExecutor.swift`: app-side verified Accessibility actions and clipboard fallback.

### New tests and fixtures

- `Tests/AgentHubClaudeTests/*.swift`: decoder, installer, classifier, terminal, transcript, and adapter tests.
- `Tests/AgentHubDaemonTests/ClaudeVerticalSliceTests.swift`: hook-to-daemon-to-request and handoff flow.
- `Tests/Fixtures/Claude/*.json`: supported hook payloads.
- `Tests/Fixtures/Claude/*.jsonl`: bounded transcript cases.
- `Tests/Fixtures/Claude/*.txt`: tmux screen states.

### Existing files modified

- `Package.swift`: Claude library, hook executable, and test targets.
- `Sources/AgentHubCore/Models.swift`: generic hook envelope, component status, native interaction plan, and quota-compatible optional labels.
- `Sources/AgentHubCore/AgentAdapter.swift`: hook ingestion, setup, and resolution-route extension protocols.
- `Sources/AgentHubCore/StateReducer.swift`: provider component state.
- `Sources/AgentHubPersistence/Database.swift` and `Store.swift`: component status migration and persistence.
- `Sources/AgentHubIPC/Messages.swift`: protocol v3 hook/setup/native-interaction messages.
- `Sources/AgentHubDaemon/Coordinator.swift`, `RequestService.swift`, and `DaemonAPI.swift`: route new commands safely.
- `Sources/agenthubd/main.swift`: construct and register `ClaudeAdapter`.
- `App/DaemonInstallation.swift`, `project.yml`: embed and atomically install the hook helper beside `agenthubd`.
- `App/Features/Dashboard/*`, `App/Features/Requests/RequestInboxView.swift`, `App/Features/Sessions/SessionDetailView.swift`, and `App/JumpOpener.swift`: Claude launch, setup, request actions, handoff fallback, and navigation.
- `scripts/check.sh`, `README.md`, and `docs/development.md`: static privacy gates and operating instructions.

---

### Task 1: Provider-neutral hook, component, and native-interaction contracts

**Files:**
- Modify: `Sources/AgentHubCore/Models.swift`
- Modify: `Sources/AgentHubCore/AgentAdapter.swift`
- Modify: `Sources/AgentHubCore/StateReducer.swift`
- Test: `Tests/AgentHubCoreTests/ModelTests.swift`
- Test: `Tests/AgentHubCoreTests/StateReducerTests.swift`

**Interfaces:**
- Produces: `ProviderHookEnvelope`, `ProcessObservation`, `ProviderComponentStatus`, `ProviderConfigurationAction`, `NativeInteractionOperation`, `NativeInteractionPlan`, and `RequestResolutionRoute`.
- Produces: `HookEventIngestingAdapter.ingest(_:)`, `ProviderConfigurableAdapter.configure(_:)`, and the default `AgentAdapter.resolutionRoute(_:decision:) -> .provider`.
- Preserves: existing `AgentAdapter.resolve` for structured provider acknowledgements.

- [ ] **Step 1: Write failing model and reducer tests**

```swift
func testProviderHookEnvelopeRejectsMoreThan256KiB() {
    XCTAssertThrowsError(try ProviderHookEnvelope(
        provider: .claude,
        rawJSON: Data(repeating: 1, count: 256 * 1_024 + 1),
        sourcePID: 42,
        ancestors: [],
        observedAt: Date()
    )) { error in
        XCTAssertEqual(error as? ProviderHookEnvelopeError, .oversizedPayload)
    }
}

func testComponentUpsertUsesProviderAndComponentIdentity() {
    var state = AgentHubState.empty
    let status = ProviderComponentStatus(
        provider: .claude,
        component: "hooks",
        available: true,
        version: "2.1.228",
        path: "/tmp/agenthub-claude-hook",
        message: nil,
        changedAt: Date(timeIntervalSince1970: 1)
    )
    StateReducer.reduce(state: &state, event: .componentUpserted(status))
    XCTAssertEqual(state.components["claude:hooks"], status)
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `swift test --filter 'ModelTests|StateReducerTests'`

Expected: compilation fails because the hook, component, native interaction, and event types do not exist.

- [ ] **Step 3: Implement the minimal provider-neutral contracts**

```swift
public struct ProcessObservation: Codable, Equatable, Sendable {
    public let pid: Int32
    public let parentPID: Int32
    public let uid: UInt32
    public let tty: String?
    public let command: String
}

public struct ProviderHookEnvelope: Codable, Equatable, Sendable {
    public static let maximumPayloadBytes = 256 * 1_024
    public let provider: Provider
    public let rawJSON: Data
    public let sourcePID: Int32
    public let ancestors: [ProcessObservation]
    public let observedAt: Date
}

public struct ProviderComponentStatus: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(provider.rawValue):\(component)" }
    public let provider: Provider
    public let component: String
    public let available: Bool
    public let version: String?
    public let path: String?
    public let message: String?
    public let changedAt: Date
}

public enum ProviderConfigurationAction: String, Codable, Sendable {
    case installHooks, uninstallHooks, refreshComponents
}

public enum NativeInteractionOperation: Codable, Equatable, Sendable {
    case choose(label: String)
    case enter(text: String)
}

public struct NativeInteractionPlan: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let provider: Provider
    public let requestID: UUID
    public let bundleID: String
    public let windowHint: String?
    public let sessionNativeID: String
    public let promptFingerprint: String
    public let operation: NativeInteractionOperation
}

public enum RequestResolutionRoute: Codable, Equatable, Sendable {
    case provider
    case native(NativeInteractionPlan)
}
```

Add `.componentUpserted(ProviderComponentStatus)` to `AgentEvent`, add
`components: [String: ProviderComponentStatus]` to `AgentHubState`, and add the
three extension protocols with a default `.provider` resolution route.

- [ ] **Step 4: Run focused tests and the core suite**

Run: `swift test --filter AgentHubCoreTests`

Expected: all core tests pass and existing Codex/OpenCode adapter source still compiles through the default resolution route.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentHubCore Tests/AgentHubCoreTests
git commit -m "feat: define provider hook interaction contracts"
```

---

### Task 2: Persist component health and carry hook/setup actions over IPC

**Files:**
- Modify: `Sources/AgentHubPersistence/Database.swift`
- Modify: `Sources/AgentHubPersistence/Store.swift`
- Modify: `Sources/AgentHubIPC/Messages.swift`
- Test: `Tests/AgentHubPersistenceTests/StoreTests.swift`
- Test: `Tests/AgentHubIPCTests/IPCTests.swift`

**Interfaces:**
- Consumes: Task 1 models.
- Produces daemon commands: `.ingestProviderHook(ProviderHookEnvelope)`, `.configureProvider(Provider, ProviderConfigurationAction)`, and `.nativeInteractionStarted(requestID:planID:)`.
- Produces daemon replies: `.components([ProviderComponentStatus])` and `.nativeInteraction(NativeInteractionPlan)`.
- Sets `agentHubIPCProtocolVersion` to `3`.

- [ ] **Step 1: Write failing persistence and IPC round-trip tests**

```swift
func testProviderComponentSurvivesRestart() async throws {
    let url = temporaryDatabaseURL()
    let store = try AgentHubStore(databaseURL: url)
    let component = ProviderComponentStatus(
        provider: .claude, component: "hooks", available: true,
        version: "2.1.228", path: "/tmp/hook", message: nil,
        changedAt: Date(timeIntervalSince1970: 1)
    )
    try await store.apply(.componentUpserted(component))
    XCTAssertEqual(try await AgentHubStore(databaseURL: url).snapshot().components[component.id], component)
}

func testProtocolV3RoundTripsBoundedClaudeHook() throws {
    let hook = try ProviderHookEnvelope(
        provider: .claude, rawJSON: Data("{\"hook_event_name\":\"SessionStart\"}".utf8),
        sourcePID: 42, ancestors: [], observedAt: Date(timeIntervalSince1970: 1)
    )
    let data = try JSONLineCodec.encode(IPCEnvelope(body: DaemonCommand.ingestProviderHook(hook)))
    let decoded = try JSONDecoder.agentHub.decode(IPCEnvelope<DaemonCommand>.self, from: data)
    XCTAssertEqual(decoded.protocolVersion, 3)
}
```

- [ ] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter 'StoreTests|IPCTests'`

Expected: failures mention missing component table/event cases and missing IPC commands.

- [ ] **Step 3: Add migration, store branches, and IPC cases**

Register `provider-components-v3` with `id`, `provider`, `component`, and `body`
columns. Persist and restore `ProviderComponentStatus`. Extend all exhaustive
switches and update IPC protocol fixtures from v2 to v3. Decode-time daemon
validation must reject an oversized `rawJSON` even if a crafted payload bypasses
the public initializer.

- [ ] **Step 4: Run persistence and IPC suites**

Run: `swift test --filter 'AgentHubPersistenceTests|AgentHubIPCTests'`

Expected: all tests pass, including existing database migration and socket-mode tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentHubPersistence Sources/AgentHubIPC Tests/AgentHubPersistenceTests Tests/AgentHubIPCTests
git commit -m "feat: transport provider hook events"
```

---

### Task 3: Decode Claude lifecycle, request, subagent, and task hooks

**Files:**
- Modify: `Package.swift`
- Create: `Sources/AgentHubClaude/Bootstrap.swift`
- Create: `Sources/AgentHubClaude/ClaudeHookModels.swift`
- Create: `Tests/AgentHubClaudeTests/BootstrapTests.swift`
- Create: `Tests/AgentHubClaudeTests/ClaudeHookModelsTests.swift`
- Create: `Tests/Fixtures/Claude/session-start.json`
- Create: `Tests/Fixtures/Claude/permission-request.json`
- Create: `Tests/Fixtures/Claude/ask-user-question.json`
- Create: `Tests/Fixtures/Claude/subagent-start.json`
- Create: `Tests/Fixtures/Claude/subagent-stop.json`
- Create: `Tests/Fixtures/Claude/task-created.json`
- Create: `Tests/Fixtures/Claude/task-completed.json`
- Create: `Tests/Fixtures/Claude/unknown-event.json`

**Interfaces:**
- Produces: `ClaudeHookDecoder.decode(_:) -> ClaudeHookEvent`.
- Produces common values: `sessionID`, `transcriptPath`, `cwd`, `eventName`, `agentID`, `agentType`, `toolName`, `toolInput`, `notificationType`, and `lastAssistantMessage`.
- Keeps arbitrary JSON values internal to `AgentHubClaude`.

- [ ] **Step 1: Add fixtures and failing decoder tests**

```swift
func testPermissionAndQuestionDecodeWithoutLosingFieldOrder() throws {
    let permission = try decoder.decode(fixture("permission-request"))
    guard case .permissionRequest(let value) = permission else { return XCTFail() }
    XCTAssertEqual(value.common.sessionID, "abc123")
    XCTAssertEqual(value.toolName, "Bash")

    let question = try decoder.decode(fixture("ask-user-question"))
    guard case .preToolUse(let value) = question else { return XCTFail() }
    XCTAssertEqual(value.toolName, "AskUserQuestion")
    XCTAssertEqual(value.questions.map(\.prompt), ["Environment?", "Checks?"])
}

func testUnknownEventIsPreservedAsIgnoredName() throws {
    XCTAssertEqual(try decoder.decode(fixture("unknown-event")), .unknown("FutureEvent"))
}
```

- [ ] **Step 2: Run Claude tests and verify RED**

Run: `swift test --filter AgentHubClaudeTests`

Expected: target or symbols are missing.

- [ ] **Step 3: Implement strict common fields with additive payload tolerance**

Define an internal recursive `ClaudeJSONValue`, decode `hook_event_name` first,
and map known events into typed associated values. Reject a missing session ID,
transcript path, cwd, or known-event required field with a coarse
`ClaudeHookDecodingError`; return `.unknown(name)` for unsupported event names.

- [ ] **Step 4: Run Claude decoder tests**

Run: `swift test --filter ClaudeHookModelsTests`

Expected: supported fixtures decode, field order remains stable, unknown data does not fail the decoder.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/AgentHubClaude Tests/AgentHubClaudeTests Tests/Fixtures/Claude
git commit -m "feat: decode Claude lifecycle hooks"
```

---

### Task 4: Install and uninstall AgentHub hooks without damaging user settings

**Files:**
- Create: `Sources/AgentHubClaude/ClaudeHookInstaller.swift`
- Create: `Tests/AgentHubClaudeTests/ClaudeHookInstallerTests.swift`

**Interfaces:**
- Produces: `ClaudeHookInstaller.status()`, `install()`, and `uninstall()`.
- Produces component name `hooks` with exact path and installation state.
- Consumes: absolute packaged `agenthub-claude-hook` URL and an injectable Claude settings URL.

- [ ] **Step 1: Write failing isolated-settings tests**

```swift
func testInstallPreservesExistingHooksAndIsIdempotent() throws {
    try writeSettings(["theme": "dark", "hooks": ["Stop": existingStopHook]])
    try installer.install()
    try installer.install()
    let settings = try readSettings()
    XCTAssertEqual(settings["theme"] as? String, "dark")
    XCTAssertEqual(agentHubCommands(in: settings, event: "SessionStart").count, 1)
    XCTAssertEqual(existingCommands(in: settings, event: "Stop"), ["/usr/local/bin/existing-hook"])
}

func testUninstallRemovesOnlyExactAgentHubExecutable() throws {
    try installer.install()
    try installer.uninstall()
    XCTAssertTrue(agentHubCommands(in: try readSettings(), event: "SessionStart").isEmpty)
    XCTAssertEqual(existingCommands(in: try readSettings(), event: "Stop"), ["/usr/local/bin/existing-hook"])
}
```

Also test malformed JSON leaves original bytes unchanged and new/replaced files
have mode `0600`.

- [ ] **Step 2: Run installer tests and verify RED**

Run: `swift test --filter ClaudeHookInstallerTests`

Expected: missing installer errors.

- [ ] **Step 3: Implement parse-copy-validate-atomic-replace**

Create command-hook entries for the event list in the approved design. Set
`"async": true` on observer hooks, an absolute executable command, and a short
timeout. Match ownership only by the normalized exact executable path; do not
delete by event name or generic substring. Use a sibling staged file and
`replaceItemAt`/`moveItem`, then set mode `0600`.

- [ ] **Step 4: Run installer and Claude suites**

Run: `swift test --filter AgentHubClaudeTests`

Expected: all tests pass using temporary settings only.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentHubClaude/ClaudeHookInstaller.swift Tests/AgentHubClaudeTests/ClaudeHookInstallerTests.swift
git commit -m "feat: manage user scoped Claude hooks"
```

---

### Task 5: Package a bounded one-shot Claude hook bridge

**Files:**
- Create: `Sources/AgentHubClaude/ClaudeHookReporter.swift`
- Create: `Sources/agenthub-claude-hook/main.swift`
- Modify: `Package.swift`
- Modify: `project.yml`
- Modify: `App/DaemonInstallation.swift`
- Test: `Tests/AgentHubClaudeTests/ClaudeHookReporterTests.swift`
- Test: `Tests/AgentHubAppTests/DaemonInstallationTests.swift`

**Interfaces:**
- Produces executable product `agenthub-claude-hook`.
- Produces: `ClaudeHookReporter.report(stdin:sourcePID:) async throws`.
- Installs helper at `~/Library/Application Support/AgentHub/bin/agenthub-claude-hook` with mode `0700`.

- [ ] **Step 1: Write failing reporter and packaging tests**

```swift
func testReporterSendsBoundedEnvelopeWithoutEnvironment() async throws {
    let sink = RecordingHookSink()
    let reporter = ClaudeHookReporter(
        ancestry: { _ in [.init(pid: 40, parentPID: 1, uid: 501, tty: "ttys001", command: "claude")] },
        send: { await sink.record($0) }, now: { Date(timeIntervalSince1970: 1) }
    )
    try await reporter.report(stdin: Data("{\"hook_event_name\":\"SessionStart\"}".utf8), sourcePID: 41)
    XCTAssertEqual(await sink.values().single?.provider, .claude)
    XCTAssertFalse(String(data: await sink.values().single!.rawJSON, encoding: .utf8)!.contains("PATH"))
}
```

Extend `DaemonInstallationTests` to assert both helpers are atomically copied,
executable, and never written into the plist arguments.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter 'ClaudeHookReporterTests|DaemonInstallationTests'`

Expected: missing reporter/product/path failures.

- [ ] **Step 3: Implement the reporter, thin main, and dual-helper installation**

The executable reads at most 256 KiB from stdin, resolves the AgentHub socket
under Application Support, captures bounded current-user ancestry, sends
`.ingestProviderHook`, and exits zero on connection/timeout failure so Claude is
never blocked. Add an explicit 500 ms end-to-end timeout. The Xcode post-build
step builds and embeds both executable products; `DaemonInstallation.install`
requires and stages both before restarting the LaunchAgent.

- [ ] **Step 4: Verify package and Xcode project generation**

Run: `swift test --filter 'ClaudeHookReporterTests|DaemonInstallationTests' && xcodegen generate`

Expected: tests pass and `AgentHub.xcodeproj` is generated with two embedded helpers.

- [ ] **Step 5: Commit**

```bash
git add Package.swift project.yml Sources/AgentHubClaude/ClaudeHookReporter.swift Sources/agenthub-claude-hook App/DaemonInstallation.swift Tests/AgentHubClaudeTests Tests/AgentHubAppTests
git commit -m "feat: package Claude hook bridge"
```

---

### Task 6: Manage Claude in tmux and attach it to iTerm

**Files:**
- Create: `Sources/AgentHubClaude/ClaudeTerminalRuntime.swift`
- Create: `Tests/AgentHubClaudeTests/ClaudeTerminalRuntimeTests.swift`

**Interfaces:**
- Produces: `ClaudeManagedRuntime(sessionName:paneID:claudeSessionID:cwd:)`.
- Produces protocol: `ClaudeTerminalControlling.launch`, `listManaged`, `capture`, `pasteLiteral`, `submit`, `select`, and `isAlive`.
- Consumes: resolved Claude, tmux, and osascript executable URLs.

- [ ] **Step 1: Write failing command-construction and reconciliation tests**

```swift
func testLaunchUsesFixedSessionIDAndNeverPutsPromptInArguments() async throws {
    let runner = RecordingCommandRunner()
    let runtime = TmuxClaudeTerminalRuntime(run: runner.run)
    _ = try await runtime.launch(
        name: "agenthub-a1b2c3d4", claudeSessionID: claudeID,
        title: "Fix tests", cwd: "/tmp/repo", model: "sonnet"
    )
    let calls = await runner.calls()
    let arguments = calls.first!.arguments
    let sessionIDIndex = try XCTUnwrap(arguments.firstIndex(of: "--session-id"))
    XCTAssertEqual(arguments[sessionIDIndex + 1], claudeID.uuidString)
    XCTAssertFalse(calls.flatMap(\.arguments).contains("Build it"))
    XCTAssertTrue(calls.contains { $0.executable == "/usr/bin/osascript" })
}
```

Also verify `listManaged` accepts only the `agenthub-` prefix and returns pane
IDs from tmux's formatted machine output.

- [ ] **Step 2: Run terminal tests and verify RED**

Run: `swift test --filter ClaudeTerminalRuntimeTests`

Expected: missing runtime types.

- [ ] **Step 3: Implement shell-free Process invocations**

Invoke tmux directly with argument arrays. Start Claude without the instruction:

```text
tmux new-session -d -s agenthub-<id> -c <cwd> -- <claude> --session-id <uuid> --name <title> [--model <model>]
```

Use `tmux load-buffer -` with stdin plus `paste-buffer -d` for literal text. Use
static AppleScript with values passed in `argv` to open or focus an iTerm tmux
attachment. Do not build a shell command from prompt, cwd, or title.

- [ ] **Step 4: Run terminal and privacy-focused tests**

Run: `swift test --filter 'ClaudeTerminalRuntimeTests|PrivacyTests'`

Expected: all tests pass and captured process arguments contain no prompt text.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentHubClaude/ClaudeTerminalRuntime.swift Tests/AgentHubClaudeTests/ClaudeTerminalRuntimeTests.swift
git commit -m "feat: run Claude in visible managed terminals"
```

---

### Task 7: Parse terminal state and execute only exact managed requests

**Files:**
- Create: `Sources/AgentHubClaude/ClaudeTerminalScreen.swift`
- Create: `Tests/AgentHubClaudeTests/ClaudeTerminalScreenTests.swift`
- Create: `Tests/Fixtures/Claude/idle-screen.txt`
- Create: `Tests/Fixtures/Claude/working-screen.txt`
- Create: `Tests/Fixtures/Claude/permission-screen.txt`
- Create: `Tests/Fixtures/Claude/question-screen.txt`

**Interfaces:**
- Produces: `ClaudeTerminalScreen.parse(_:)`, `fingerprint`, `isIdleComposer`, and `requestOptions`.
- Produces: `ClaudeManagedRequestExecutor.resolve(decision:expectedFingerprint:runtime:)`.
- Consumes: Task 6 capture and literal-input methods.

- [ ] **Step 1: Write failing screen and stale-request tests**

```swift
func testPermissionScreenMapsVisibleLabelsAndStableFingerprint() throws {
    let screen = try ClaudeTerminalScreen.parse(fixture("permission-screen"))
    XCTAssertEqual(screen.requestOptions.map(\.label), ["Yes", "Yes, and don't ask again", "No"])
    XCTAssertFalse(screen.fingerprint.isEmpty)
}

func testExecutorRejectsChangedPromptBeforeSendingKeys() async throws {
    let terminal = FakeTerminal(captured: fixture("working-screen"))
    await XCTAssertThrowsErrorAsync(
        try await executor.resolve(.accept, expectedFingerprint: "old", runtime: managed, terminal: terminal)
    )
    XCTAssertTrue(await terminal.sentInputs().isEmpty)
}
```

- [ ] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter ClaudeTerminalScreenTests`

Expected: parser and executor are missing.

- [ ] **Step 3: Implement ANSI stripping, canonicalization, and label-based actions**

Hash the canonicalized bounded prompt text with CryptoKit SHA-256. A decision is
valid only when Claude UUID, tmux pane process, current prompt fingerprint, and
visible option label all match. Map `.accept`, `.acceptForSession`, `.decline`,
`.cancel`, `.choices`, `.answers`, and `.text` to visible labels or literal input;
throw `ClaudeTerminalError.stalePrompt` when any required match is absent.

- [ ] **Step 4: Run screen and terminal suites**

Run: `swift test --filter 'ClaudeTerminalScreenTests|ClaudeTerminalRuntimeTests'`

Expected: exact states pass and ambiguous/changed screens send no input.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentHubClaude/ClaudeTerminalScreen.swift Tests/AgentHubClaudeTests Tests/Fixtures/Claude
git commit -m "feat: validate Claude terminal requests"
```

---

### Task 8: Read only bounded visible turns from safe Claude transcripts

**Files:**
- Create: `Sources/AgentHubClaude/ClaudeTranscriptReader.swift`
- Create: `Tests/AgentHubClaudeTests/ClaudeTranscriptReaderTests.swift`
- Create: `Tests/Fixtures/Claude/transcript.jsonl`
- Create: `Tests/Fixtures/Claude/transcript-unknown.jsonl`

**Interfaces:**
- Produces: `ClaudeTranscriptReading.recentTurns(path:limit:) -> [VisibleTurn]`.
- Consumes: configured Claude data root and provider transcript reference.

- [ ] **Step 1: Write failing bounds and path-safety tests**

```swift
func testReadsNewestTwentyVisibleTurnsAndIgnoresUnknownRecords() throws {
    let turns = try reader.recentTurns(path: safeTranscript.path, limit: 100)
    XCTAssertEqual(turns.count, 20)
    XCTAssertTrue(turns.allSatisfy { $0.role == "user" || $0.role == "assistant" })
}

func testRejectsEscapeAndSymlinkOutsideClaudeRoot() throws {
    XCTAssertThrowsError(try reader.recentTurns(path: outside.path, limit: 3))
    XCTAssertThrowsError(try reader.recentTurns(path: escapingSymlink.path, limit: 3))
}
```

- [ ] **Step 2: Run transcript tests and verify RED**

Run: `swift test --filter ClaudeTranscriptReaderTests`

Expected: reader is missing.

- [ ] **Step 3: Implement canonical-root validation and streaming JSONL decode**

Resolve standardized and symlink-resolved URLs, require the file below the
configured Claude root, cap a record at 256 KiB, cap the requested limit at 20,
and emit only visible user/assistant text. Unknown records and content blocks are
ignored; malformed known records return a coarse transcript error without
exposing their body.

- [ ] **Step 4: Run transcript and persistence privacy tests**

Run: `swift test --filter 'ClaudeTranscriptReaderTests|StoreTests'`

Expected: bounded reads pass and existing preview persistence caps remain green.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentHubClaude/ClaudeTranscriptReader.swift Tests/AgentHubClaudeTests Tests/Fixtures/Claude
git commit -m "feat: read bounded Claude transcript previews"
```

---

### Task 9: Normalize Claude sessions, subagents, tasks, and first-responder requests

**Files:**
- Create: `Sources/AgentHubClaude/ClaudeProcessClassifier.swift`
- Create: `Sources/AgentHubClaude/ClaudeAdapter.swift`
- Create: `Tests/AgentHubClaudeTests/ClaudeProcessClassifierTests.swift`
- Create: `Tests/AgentHubClaudeTests/ClaudeAdapterTests.swift`

**Interfaces:**
- Implements: `AgentAdapter`, `HookEventIngestingAdapter`, and `ProviderConfigurableAdapter`.
- Produces surfaces: `Managed CLI`, `External CLI`, and `Desktop`.
- Produces deterministic session/node/request UUIDs from account, native session ID, agent/task ID, and request fingerprint.

- [ ] **Step 1: Write failing lifecycle, tree, and request tests**

```swift
func testHooksCreateSeparateCLIAndDesktopSessionsAndExplicitNodes() async throws {
    try await adapter.ingest(cliSessionStart)
    try await adapter.ingest(desktopSessionStart)
    try await adapter.ingest(subagentStart)
    let snapshot = try await adapter.reconcile()
    XCTAssertEqual(snapshot.sessions.map(\.surface).sorted(), ["Desktop", "External CLI"])
    XCTAssertEqual(snapshot.nodes.single?.nativeID, "agent-abc123")
    XCTAssertEqual(snapshot.nodes.single?.parentNativeID, nil)
}

func testNativeResolutionRouteContainsNoRawToolPayload() async throws {
    try await adapter.ingest(desktopPermission)
    let request = try XCTUnwrap(try await adapter.reconcile().requests.single)
    let route = try await adapter.resolutionRoute(providerRef(request), decision: .accept)
    guard case .native(let plan) = route else { return XCTFail() }
    XCTAssertEqual(plan.bundleID, "com.anthropic.claudefordesktop")
    XCTAssertFalse(String(describing: plan).contains("rm -rf"))
}
```

Also test `UserPromptSubmit -> working`, request -> waiting state, `Stop -> idle`,
normal `SessionEnd -> completed`, unverified disappearance -> disconnected,
`PostToolUse`/`PermissionDenied` closes matching requests, and duplicate hook
events are idempotent.

- [ ] **Step 2: Run adapter tests and verify RED**

Run: `swift test --filter 'ClaudeProcessClassifierTests|ClaudeAdapterTests'`

Expected: classifier and adapter are missing.

- [ ] **Step 3: Implement classification and normalized state maps**

Classify Desktop only from a current-user ancestry command under
`Claude.app/Contents/MacOS`; classify managed CLI from the registered tmux/Claude
UUID pair; otherwise use External CLI. Keep raw decoded events only for the
duration of `ingest`. Store request routes in actor memory keyed by the stable
provider request fingerprint. External/Desktop sessions expose L2 observation,
L3 jump/request resolution, and no managed `sendInput` capability.

- [ ] **Step 4: Run all Claude adapter tests**

Run: `swift test --filter AgentHubClaudeTests`

Expected: all Claude unit tests pass without touching real processes or settings.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentHubClaude/ClaudeProcessClassifier.swift Sources/AgentHubClaude/ClaudeAdapter.swift Tests/AgentHubClaudeTests
git commit -m "feat: normalize Claude agent activity"
```

---

### Task 10: Launch, hand off to, resolve, and jump to managed Claude sessions

**Files:**
- Modify: `Sources/AgentHubClaude/ClaudeAdapter.swift`
- Test: `Tests/AgentHubClaudeTests/ClaudeAdapterManagedRuntimeTests.swift`

**Interfaces:**
- Consumes: Task 6 terminal control, Task 7 request executor, Task 8 transcript reader.
- Implements: `launch`, `recentTurns`, `send`, `resolve`, and `jumpTarget` for managed Claude sessions.

- [ ] **Step 1: Write failing managed vertical behavior tests**

```swift
func testLaunchWaitsForMatchingSessionStartThenPastesPromptOnce() async throws {
    let launch = Task { try await adapter.launch(.fixture(prompt: "Build it")) }
    try await adapter.ingest(managedSessionStart)
    let reference = try await launch.value
    XCTAssertEqual(reference.nativeID, claudeID.uuidString.lowercased())
    XCTAssertEqual(await terminal.pastedTexts(), ["Build it"])
    XCTAssertEqual(await terminal.submitCount(), 1)
}

func testSendRejectsBusyOrRequestingManagedTarget() async throws {
    try await establishManagedSession(status: .working)
    await XCTAssertThrowsErrorAsync(try await adapter.send(.init(text: "handoff"), to: reference))
    XCTAssertTrue(await terminal.pastedTexts().isEmpty)
}
```

Also verify launch timeout leaves one recoverable session, exact request
resolution uses the captured fingerprint, and jump selects/reopens the same tmux
session before returning iTerm activation.

- [ ] **Step 2: Run managed adapter tests and verify RED**

Run: `swift test --filter ClaudeAdapterManagedRuntimeTests`

Expected: launch/send/resolve behavior is unimplemented or fails assertions.

- [ ] **Step 3: Implement bounded launch handshake and runtime validation**

Register the managed UUID before starting tmux, wait up to 30 seconds for its
matching `SessionStart`, require an idle composer, paste the initial instruction
once, and await `UserPromptSubmit` as acknowledgement. `send` requires an idle
managed session with no pending request. `resolve` delegates to the exact managed
request executor. `jumpTarget` selects or reattaches tmux and returns
`.application(bundleID:"com.googlecode.iterm2", windowHint:sessionName)`.

- [ ] **Step 4: Run Claude suites**

Run: `swift test --filter AgentHubClaudeTests`

Expected: all Claude tests pass, including zero prompt text in process arguments.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentHubClaude/ClaudeAdapter.swift Tests/AgentHubClaudeTests/ClaudeAdapterManagedRuntimeTests.swift
git commit -m "feat: control managed Claude sessions"
```

---

### Task 11: Wire Claude hooks, setup actions, native plans, and queued delivery through the daemon

**Files:**
- Modify: `Sources/AgentHubDaemon/Coordinator.swift`
- Modify: `Sources/AgentHubDaemon/RequestService.swift`
- Modify: `Sources/AgentHubDaemon/DaemonAPI.swift`
- Create: `Sources/AgentHubDaemon/DeliveryReconciler.swift`
- Modify: `Sources/agenthubd/main.swift`
- Test: `Tests/AgentHubDaemonTests/RequestServiceTests.swift`
- Test: `Tests/AgentHubDaemonTests/ClaudeVerticalSliceTests.swift`
- Test: `Tests/AgentHubDaemonTests/HandoffServiceTests.swift`

**Interfaces:**
- Produces: `Coordinator.ingest(_ hook:)`, `configure(provider:action:)`.
- Changes: `RequestService.resolve` returns either acknowledged completion or a native interaction plan.
- Produces: `RequestService.nativeInteractionStarted(requestID:planID:)`.
- Produces: `DeliveryReconciler` consuming coordinator changes and invoking `HandoffService.sessionBecameIdle` once per working-to-idle transition.

- [ ] **Step 1: Write failing request-route and Claude vertical-slice tests**

```swift
func testNativeRequestRemainsPendingUntilAppStartsMatchingPlan() async throws {
    let result = try await service.resolve(id: request.id, decision: .accept)
    guard case .native(let plan) = result else { return XCTFail() }
    XCTAssertEqual(try await store.snapshot().requests[request.id]?.state, .pending)
    try await service.nativeInteractionStarted(requestID: request.id, planID: plan.id)
    XCTAssertEqual(try await store.snapshot().requests[request.id]?.state, .resolving)
}

func testClaudeHookReachesSnapshotAndIdleTransitionReleasesOneHandoff() async throws {
    _ = await api.handle(.ingestProviderHook(sessionStart))
    _ = await api.handle(.ingestProviderHook(stopEvent))
    XCTAssertEqual(await recordingAdapter.sentInputs().count, 1)
}
```

- [ ] **Step 2: Run daemon tests and verify RED**

Run: `swift test --filter AgentHubDaemonTests`

Expected: missing coordinator/API routes and delivery reconciler failures.

- [ ] **Step 3: Implement optional-protocol routing and daemon composition**

Reject a hook whose provider does not match the ingesting adapter. For structured
routes, preserve existing start/acknowledge/audit behavior. For native routes,
cache the plan in `RequestService`, return it without changing persisted request
state, and transition to resolving only when the app reports the same request and
plan IDs. Register `.claude` in all three adapter maps and shut it down cleanly.

Start one `DeliveryReconciler` task after coordinator startup; cancel it during
daemon shutdown. It compares prior/current state so repeated snapshots do not
redeliver an envelope.

- [ ] **Step 4: Run daemon and IPC suites**

Run: `swift test --filter 'AgentHubDaemonTests|AgentHubIPCTests'`

Expected: existing Codex/OpenCode flows and the Claude hook flow all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentHubDaemon Sources/agenthubd Tests/AgentHubDaemonTests
git commit -m "feat: expose Claude through the daemon"
```

---

### Task 12: Add Claude launch, settings, Accessibility navigation, native request execution, and manual handoff UI

**Files:**
- Create: `App/Features/Claude/ClaudeSettingsView.swift`
- Create: `App/ClaudeNativeInteractionExecutor.swift`
- Modify: `App/Features/Dashboard/DashboardView.swift`
- Modify: `App/Features/Dashboard/DashboardViewModel.swift`
- Modify: `App/Features/Sessions/SessionTreeView.swift`
- Modify: `App/Features/Sessions/SessionDetailView.swift`
- Modify: `App/Features/Requests/RequestInboxView.swift`
- Modify: `App/JumpOpener.swift`
- Test: `Tests/AgentHubAppTests/DashboardViewModelTests.swift`
- Create: `Tests/AgentHubAppTests/ClaudeNativeInteractionExecutorTests.swift`

**Interfaces:**
- Produces: `NativeInteractionExecuting.execute(_:) async throws` and `ClipboardWriting.write(_:)`.
- Consumes: `.nativeInteraction` daemon reply and reports `.nativeInteractionStarted` only after a successful verified UI action.
- Shows provider component states from `AgentHubState.components`.

- [ ] **Step 1: Write failing view-model and executor tests**

```swift
func testClaudeNativeResolutionExecutesPlanThenMarksItStarted() async throws {
    client.replies = [.nativeInteraction(plan), .completed, .snapshot(state)]
    await model.resolve(request.id, decision: .accept)
    XCTAssertEqual(await nativeExecutor.plans(), [plan])
    XCTAssertTrue(client.commands.contains(.nativeInteractionStarted(requestID: request.id, planID: plan.id)))
}

func testManualHandoffCopiesRenderedEnvelopeAndJumpsWithoutSubmitting() async throws {
    client.replies = [.accepted(envelope.id), .snapshot(stateWithManualEnvelope), .jump(.application(bundleID: claudeBundleID, windowHint: "session"))]
    await model.handoff(source: source.id, target: desktop.id, turnLimit: 3, note: nil)
    XCTAssertTrue(clipboard.value.contains("AgentHub handoff from"))
    XCTAssertTrue(await nativeExecutor.plans().isEmpty)
}
```

Executor tests must verify ambiguous windows, missing Accessibility permission,
wrong session title, wrong project, and wrong prompt fingerprint cause zero click,
paste, or submit actions.

- [ ] **Step 2: Run app tests and verify RED**

Run: `xcodegen generate && xcodebuild -project AgentHub.xcodeproj -scheme AgentHubApp -destination 'platform=macOS' -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO test`

Expected: missing Claude UI/executor and reply handling failures.

- [ ] **Step 3: Implement minimal Claude UI and app-side safety checks**

Add Claude to the New Task provider picker. Allow the composer and automatic
handoff target only when `.sendInput` exists and the adapter will validate it;
include unmanaged live Claude sessions as manual handoff targets. `ClaudeSettingsView`
shows binary, hooks, tmux, iTerm, and Accessibility components with install,
uninstall, and refresh controls.

The concrete executor uses `AXIsProcessTrustedWithOptions`, finds exactly one
application/window/session/request match, re-reads visible text, verifies the
plan fingerprint, and then selects the named option or enters literal text. It
never uses screen coordinates. On failure, preserve the request as pending and
activate the provider application only.

- [ ] **Step 4: Run all app tests**

Run: `xcodebuild -project AgentHub.xcodeproj -scheme AgentHubApp -destination 'platform=macOS' -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO test`

Expected: app tests pass with fakes and no actual Accessibility prompt.

- [ ] **Step 5: Commit**

```bash
git add App Tests/AgentHubAppTests
git commit -m "feat: add Claude controls to the dashboard"
```

---

### Task 13: Add full verification, privacy gates, and operating documentation

**Files:**
- Modify: `scripts/check.sh`
- Modify: `README.md`
- Modify: `docs/development.md`
- Create: `docs/claude-testing.md`
- Modify: `Tests/AgentHubDaemonTests/PrivacyTests.swift`
- Create: `Tests/AgentHubClaudeTests/LiveClaudeTests.swift`

**Interfaces:**
- Produces environment flags: `AGENTHUB_LIVE_CLAUDE_SMOKE=1` for non-prompt compatibility checks and `AGENTHUB_LIVE_CLAUDE_PROMPT=1` for the separately acknowledged quota-consuming test.
- Adds static embedded-helper/module and secret/prompt-argument checks.

- [ ] **Step 1: Write failing privacy and packaging assertions**

```swift
func testPersistedStateDoesNotContainRawClaudeHookOrEnvironment() async throws {
    try await coordinator.ingest(hookContainingSensitiveToolInput)
    let bytes = try Data(contentsOf: databaseURL)
    XCTAssertFalse(bytes.contains(Data("ANTHROPIC_API_KEY".utf8)))
    XCTAssertFalse(bytes.contains(Data("raw-secret-command".utf8)))
}
```

Extend `scripts/check.sh` to require both embedded helpers, verify
`AgentHubClaude` is statically linked into `agenthubd`, and fail when production
source passes a launch prompt as a Claude process argument.

- [ ] **Step 2: Run the full gate and verify RED on the new static checks**

Run: `zsh scripts/check.sh`

Expected: the new packaging/privacy assertion fails before its build or documentation support is complete.

- [ ] **Step 3: Complete docs and opt-in smoke boundaries**

Document hook install/uninstall, tmux/iTerm requirements, Accessibility
degradation, daemon logs, helper paths, default fixture-only tests, and the exact
live commands. The ordinary smoke test may run `claude --version`, validate a
temporary hook config, check socket delivery, and run tmux capability probes; it
must not submit a prompt. The prompt test remains skipped unless its separate
flag is present.

- [ ] **Step 4: Run clean full verification**

Run: `zsh scripts/check.sh`

Expected: Swift package tests, plist/shell checks, Xcode app tests, embedded-helper checks, and privacy checks all exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/check.sh README.md docs Tests/AgentHubDaemonTests/PrivacyTests.swift Tests/AgentHubClaudeTests/LiveClaudeTests.swift
git commit -m "test: verify the Claude session vertical slice"
```

---

## Phase A Acceptance Checklist

- [ ] `claude --version` compatibility is reported without exposing auth data.
- [ ] AgentHub hook install is idempotent and uninstall preserves every unrelated user setting.
- [ ] Managed Claude opens in iTerm backed by tmux with the initial prompt absent from process arguments.
- [ ] CLI and Desktop hooks create separate normalized sessions and explicit subagent/task nodes.
- [ ] Native and AgentHub request handling follow first-responder semantics and stale UI is never acted on.
- [ ] Managed handoffs are delivered once only when idle; unmanaged handoffs copy and jump.
- [ ] Exact managed jump works; all ambiguous external/Desktop cases display a degraded fallback.
- [ ] No default test sends a prompt, modifies real settings, reads real transcripts, or requests Accessibility.
- [ ] `zsh scripts/check.sh` exits 0.
