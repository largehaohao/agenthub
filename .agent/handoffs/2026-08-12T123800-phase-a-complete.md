# Agent Handoff

## Metadata
- created: 2026-08-12T12:38:00+0800
- source agent: `claude-opus-5`
- repository: `/Users/zhanghao/agenthub`
- implementation worktree: `/Users/zhanghao/agenthub/.worktrees/agenthub-claude`
- branch: `codex/agenthub-claude`
- HEAD: `bfe3f72` (worktree); `main` remains at `c44cf1c`

## Objective
Implement the approved AgentHub Claude provider delivery end to end: visible managed Claude Code CLI sessions, external CLI and Claude Desktop discovery, unified lifecycle/subagents/requests, safe jump and handoff behavior, and Claude subscription quota through CodexBar.

## Context Memory

### Critical Memory
- The user approved Claude Code CLI **and** Claude Desktop support.
- Managed Claude tasks must open as a visible native TUI in iTerm, backed by tmux; do not replace this with a background `stream-json` client.
- The user approved installing user-level Claude hooks so sessions launched outside AgentHub are observed. Installation must preserve existing settings and uninstall only AgentHub-owned entries.
- Permission handling is first-responder: the original Claude surface and AgentHub remain usable. AgentHub may act only after validating the exact session and current prompt.
- The user approved optional macOS Accessibility permission for Desktop navigation. Ambiguity or UI drift must degrade to app activation; never best-effort click, paste, or submit.
- Cross-agent delivery is tiered: an idle verified AgentHub-managed CLI may receive direct input; external CLI and Desktop targets use bounded clipboard-and-jump only.
- Claude subscription quota is in scope. Session support is Phase A and quota is Phase B so third-party setup/auth cannot block core Claude support.
- The user requested transfer between agents for completion. Do not repeat product-design questions; the design and plans are approved.

### Useful Memory
- Work happens in the existing worktree `.worktrees/agenthub-claude` on branch `codex/agenthub-claude`, branched from local `main` at `c44cf1c`. `.worktrees/` is gitignored.
- Local tools observed during design: Claude Code 2.1.228, tmux at `/opt/homebrew/bin/tmux`, iTerm and Claude Desktop installed. Re-verify before relying on them.
- CodexBar was not installed when checked. Its installation must be an explicit user/setup action, never silent.
- Existing AgentHub has complete Codex and OpenCode vertical slices; follow those package, adapter, daemon, IPC, SwiftUI, and fixture-test patterns.
- Fixtures load via `#filePath`-relative `Tests/Fixtures/<Provider>/<name>` (see `CodexAdapterTests.fixture`); no SwiftPM resource declarations are used.
- Default tests must not submit a Claude prompt, consume quota, modify real Claude settings, inspect real transcripts, launch iTerm, or request Accessibility.

## User Requirements
- Support Claude Code terminal and Claude Desktop in the AgentHub desktop app.
- List active Claude sessions, subagents, and background tasks.
- Centralize completion, permission, choice, and input notifications/requests when safely actionable.
- Click session rows to jump, with explicit degraded navigation when exact routing is unavailable.
- Transfer bounded output/context between Claude and other providers without manual copying where safe.
- Include Claude subscription usage and reset windows in this delivery.
- Preserve native Claude workflows and never auto-approve permissions.

## Completed
- VERIFIED: Approved design committed at `1461e4d`; Phase A/B plans committed at `c44cf1c`.
- VERIFIED: **Phase A Task 1** (`8a843f3`, plus fix `6986b5d`) — provider-neutral hook, component, and native-interaction contracts in `AgentHubCore`, including decode-time payload-size validation.
- VERIFIED: **Phase A Task 2** (`b98c14f`) — `provider-components-v3` migration, `ProviderComponentStatus` persistence/restore in `Store.swift`, IPC protocol bumped to v3 with `.ingestProviderHook`, `.configureProvider`, `.nativeInteractionStarted` commands and `.components`, `.nativeInteraction` replies. Version-specific IPC tests updated v2→v3.
- VERIFIED: **Phase A Task 3** (`279eeda`) — `AgentHubClaude` target, `Bootstrap.swift`, and `ClaudeHookModels.swift` decoding 15 known Claude events with additive-field tolerance, `.unknown(name)` fallback, and a payload-free `ClaudeHookDecodingError`. Eight fixtures added under `Tests/Fixtures/Claude/`.
- VERIFIED: **Phase A Task 4** (`4c1447c`) — `ClaudeHookInstaller` with idempotent install across 16 observed events, exact-normalized-path uninstall that spares lookalike third-party commands, malformed-JSON safety leaving original bytes intact, atomic staged replace at mode `0600`, and a `status()` returning `ProviderComponentStatus`.
- VERIFIED: **Phase A Task 5** (`090d3dc`) — `ClaudeHookReporter` (size/shape validation, sysctl ancestry, no environment capture), the `agenthub-claude-hook` executable (bounded stdin, 500 ms timeout, always exits zero), dual-helper staging in `DaemonInstallation.stageHelpers`, and `project.yml` embedding both helpers.
- VERIFIED: **Phase A Task 6** (`673549e`) — `TmuxClaudeTerminalRuntime` with shell-free `Process` argument arrays, prompt delivered via `load-buffer -` stdin + `paste-buffer -d` (never in process arguments), `agenthub-` prefix-only managed listing, and static AppleScript taking the session name through argv.
- VERIFIED: **Phase A Task 7** (`a9804ce`) — `ClaudeTerminalScreen` with ANSI stripping, whitespace-collapsing canonicalization, SHA-256 prompt fingerprints, idle/working/request detection, and `ClaudeManagedRequestExecutor` that re-captures the pane and refuses to send any input on a changed fingerprint, a dead session, or an unmatched label.
- VERIFIED: **Phase A Task 8** (`e4c6ced`) — `ClaudeTranscriptReader` capped at 20 turns and 256 KiB/record, surfacing only user/assistant `text` blocks (thinking and tool_use excluded), with symlink- and traversal-resolved root confinement.
- VERIFIED: **Phase A Task 9** (`a36f1bd`) — `ClaudeProcessClassifier` (Desktop only from `Claude.app/Contents/MacOS` ancestry; managed only from a registered UUID plus tmux ancestry) and `ClaudeAdapter` normalizing lifecycle, subagents, tasks, and requests into deterministic UUIDs, with Desktop requests routing to a payload-free `NativeInteractionPlan`.
- VERIFIED: **Phase A Task 10** (`1b4af06`) — managed `launch` (UUID registered before tmux, polled 30s handshake, idle-composer check, prompt pasted once), `send` (idle-only, no pending request), `resolve` (delegates to the executor with the fingerprint captured when the request appeared), and `jumpTarget` selecting/reattaching tmux before returning iTerm activation.
- VERIFIED: **Phase A Task 11** (`3529809`) — `Coordinator.ingest`/`configure` with provider-match rejection, `RequestService` returning `RequestResolutionOutcome` (native plans leave the request `pending` until `nativeInteractionStarted` matches both request and plan ID), real `DaemonAPI` routing for all three v3 commands, and `ClaudeAdapter` registered in `agenthubd` with capability-gated terminal resolution.
- VERIFIED: **DeliveryReconciler** (`82956e8`) — releases queued handoffs on a working→idle *transition* only; repeated idle snapshots never redeliver, and a pending request on the target blocks release. Driven from the daemon's existing relay loop.
- VERIFIED: **Phase A Task 12** (`8982e75`) — `ClaudeNativeInteractionExecutor` (refuses on missing Accessibility, no match, ambiguous match, changed fingerprint, or an option not visible — always zero UI actions), `ClaudeSettingsView`, Claude in the New Task picker and toolbar, and `DashboardViewModel.performNativeInteraction`/`configure`.
- VERIFIED: **Hook installer wiring** (`67038ac`) — `ClaudeAdapter.configure` now calls `ClaudeHookInstaller` for real, returns `[ProviderComponentStatus]` (protocol changed from `Void`), emits `.componentUpserted`, and the Coordinator persists what the adapter observed. The Claude Settings buttons now modify settings.
- VERIFIED: **Phase A Task 13** (`bfe3f72`) — `scripts/check.sh` gates (both embedded helpers present/executable, `AgentHubClaude` statically linked, `--session-id` only constructible in `ClaudeTerminalRuntime`, no permission-bypass flags), a privacy test proving no raw hook JSON / tool input / env-var name reaches the SQLite file, `docs/claude-testing.md`, README + development docs, and `LiveClaudeTests` behind two separate opt-in flags.
- VERIFIED: **`zsh scripts/check.sh` exits 0** at HEAD `bfe3f72` — the full gate (swift tests, plist lint, shell lint, xcodegen, Xcode app tests, helper/link/privacy gates).
- VERIFIED: `swift test` — 222 tests, 6 skipped (4 live Claude + 2 pre-existing), 0 failures.
- VERIFIED: Xcode app tests pass (30 tests).
- VERIFIED: The two new check.sh gates were manually proven to FAIL when violated (helper removed → exit 1; a stray `--session-id` outside the runtime → exit 1), so they are not vacuous.
- VERIFIED: `AGENTHUB_LIVE_CLAUDE_SMOKE=1 swift test --filter LiveClaudeTests` passes against real Claude 2.1.228 + tmux without submitting a prompt; the quota-consuming test stays skipped.

## Current State
- Worktree tree is clean at `bfe3f72`; `main` is untouched at `c44cf1c`.
- **PHASE A IS COMPLETE: all 13 tasks done, plus `DeliveryReconciler` and the installer wiring.** The Phase A acceptance checklist was re-verified item by item against passing tests.
- **Nothing has been pushed and no PR exists.** The branch `codex/agenthub-claude` is local only, 16 commits ahead of `main`.
- **Next is Phase B** (`docs/superpowers/plans/2026-08-12-agenthub-claude-quota.md`, 4 tasks) — or code review / integration of Phase A first, at the user's discretion.
- **KNOWN FUNCTIONAL LIMIT — read before claiming Desktop navigation works.** `App/AXClaudeAccessibilitySurface.snapshot(for:)` returns `nil` unconditionally: Claude Desktop does not expose a native session ID or prompt fingerprint through Accessibility, so no window can be matched with certainty. In practice every Desktop request therefore degrades to activating Claude. This is deliberate (never act on an unverified window) and all executor safety rules are tested against fakes, but **Desktop auto-answer is not actually functional end to end**. Filling in `snapshot(for:)` is the only change needed if a reliable identification method is found.

- `scripts/check.sh` (the full gate) has NOT been run in this worktree. `swift test` and the Xcode app test scheme have each been run directly and pass.

## Decisions

### Decision: Hooks plus managed terminal plus Desktop discovery
- choice: One Claude adapter with user-level hooks, managed tmux/iTerm runtime, external CLI discovery, and Claude Desktop discovery/navigation.
- reason: Preserves native terminal/Desktop workflows while enabling structured observation and safe managed control.
- rejected alternatives: background `stream-json` as the default; process/transcript scanning plus Accessibility without hooks.

### Decision: Capability-specific reliability
- choice: Managed CLI uses L2 validated control; external CLI/Desktop use structured observation and L3 native navigation/interaction fallbacks.
- reason: Claude exposes lifecycle hooks but no supported local interactive-session control API.

### Decision: Two implementation phases
- choice: Complete and verify Phase A sessions before Phase B CodexBar quota.

### Decision: Placeholder daemon routing for new IPC commands (this session)
- choice: Add the three v3 commands to `DaemonAPI` returning `.failure` until Task 11.
- reason: Swift exhaustive switches force a branch when the enum grows; an explicit failure is safer than a silent success before the adapter exists.

## Git State
- worktree branch: `codex/agenthub-claude`, HEAD `279eeda`, clean
- primary worktree: `main` at `c44cf1c`, only `.agent/` untracked
- commits added this session: `b98c14f`, `279eeda`
- nothing pushed; no remote branch created

## Verification

### Full Swift package suite
- command: `swift test` (run in the worktree)
- status: PASS
- result: 120 tests, 2 skipped, 0 failures at `279eeda`.

### Task-level RED/GREEN
- status: PASS
- result: Tasks 2 and 3 each verified RED on missing symbols before implementation, then GREEN.

### Full gate
- command: `zsh scripts/check.sh`
- status: NOT-RUN
- result: no current-run result is claimed. Run it before any Phase A completion claim.

## Failed Attempts

### CodeGraph project exploration
- tried: `codegraph_context` / `codegraph_status`.
- why it failed: SQLite database returned `database is locked` (reported by the prior agent; not retried this session).
- retry only if: the lock is gone; the approved plans already contain exact file/interface mappings.

### Transient git index.lock
- tried: committing Task 2.
- why it failed: `index.lock` existed momentarily; no git process was running and the lock cleared on its own. Retry succeeded. Do not delete lock files without first confirming no git process is live.

## Remaining Work
1. **Phase B**: 4 TDD tasks in `docs/superpowers/plans/2026-08-12-agenthub-claude-quota.md` (CodexBar-backed Claude subscription quota). CodexBar is NOT installed on this machine and must never be installed silently — its absence must degrade visibly.
2. Optional before Phase B: code review of the 16 Phase A commits, and the branch-finishing workflow to offer integration choices.
3. If Desktop auto-answer is wanted, find a reliable way to identify a Claude Desktop window and fill in `AXClaudeAccessibilitySurface.snapshot(for:)` (see the limitation below).
3. Run the Phase A acceptance gate and `zsh scripts/check.sh`; fix only evidence-backed failures.
4. Phase B: 4 tasks in `docs/superpowers/plans/2026-08-12-agenthub-claude-quota.md`.
5. Request code review, address verified findings, then offer integration choices via the branch-finishing workflow.
6. Do not push, merge, install CodexBar, alter real Claude settings, or request Accessibility without the relevant explicit workflow/user action.

## Recommended Next Step
Ask the user whether to (a) start Phase B quota work, or (b) review and integrate Phase A first — Phase A is a complete, independently valuable slice and nothing is pushed yet. If starting Phase B, read the quota plan fully; note that CodexBar's absence is expected and must surface as a visible unavailable state rather than an error or a silent install.

### Practical notes for the next agent
- Swift 6 rejects `await` inside an `XCTAssert*` autoclosure. Bind the actor read to a local first (`let calls = await runner.calls()`), then assert.
- The decoder requires `session_id`, `transcript_path`, and `cwd` on every known event; minimal test payloads must include them.
- Adding a `DaemonCommand`/`DaemonReply` case breaks exhaustive switches in both `Sources/AgentHubDaemon/DaemonAPI.swift` and `App/AppEnvironment.swift`.
- Adapter-specific errors follow the per-adapter enum convention (`ClaudeAdapterError`), not the two-case shared `AdapterOperationError`.
- Claude pads TUI boxes to terminal width, so screen canonicalization collapses interior whitespace runs; trimming only the line edges is not enough for a stable fingerprint.
- Never `await withCheckedContinuation` inside an actor while another actor method must resume it — that deadlocks. `ClaudeAdapter.awaitSessionStart` polls with `Task.sleep` so `ingest` can enter.
- `Task { try await adapter.method() }` inside an XCTestCase trips Swift 6 `sending` diagnostics; bind the actor to a local (`let started = adapter!`) first.
- `Coordinator.start()` reconciles every adapter, so a fake adapter's default `AdapterSnapshot.fixture()` can collide with test-inserted rows (UNIQUE constraint). Start the coordinator only in tests that need it.

## Important Constraints
- Treat live repository state as authoritative and classify drift before edits.
- Preserve the unpushed design/plan commits and the existing worktree; branch from local `main`, not `origin/main`.
- Follow both approved plan files exactly unless a verified implementation constraint requires a documented deviation.
- Each task: RED → verify RED → GREEN → verify GREEN → task-scoped commit.
- No force push, history rewrite, destructive cleanup, silent package installation, real prompt consumption, credential access, or unsafe UI automation.
- Full transcripts and raw hook events must never be persisted; enforce current preview and handoff bounds.

## References
- `docs/superpowers/specs/2026-08-12-agenthub-claude-hybrid-design.md`
- `docs/superpowers/plans/2026-08-12-agenthub-claude-sessions.md` (Task 4 is next)
- `docs/superpowers/plans/2026-08-12-agenthub-claude-quota.md`
- `Sources/AgentHubClaude/ClaudeHookModels.swift`
- `Sources/AgentHubDaemon/DaemonAPI.swift` (placeholder routing to replace in Task 11)
- `Tests/Fixtures/Claude/`
- `scripts/check.sh`
