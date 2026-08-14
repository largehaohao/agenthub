# Agent Handoff

## Metadata
- created: 2026-08-12T12:56:00+0800
- source agent: `claude-opus-5`
- repository: `/Users/zhanghao/agenthub`
- implementation worktree: `/Users/zhanghao/agenthub/.worktrees/agenthub-claude`
- branch: `codex/agenthub-claude`
- HEAD: `3e775bc` (worktree); `main` remains at `c44cf1c`

## Objective
Implement the approved AgentHub Claude provider delivery end to end: visible managed Claude Code CLI sessions, external CLI and Claude Desktop discovery, unified lifecycle/subagents/requests, safe jump and handoff behavior, and Claude subscription quota through CodexBar.

**Both approved plans are now fully implemented and verified.**

## Context Memory

### Critical Memory
- The user approved Claude Code CLI **and** Claude Desktop support.
- Managed Claude tasks open as a visible native TUI in iTerm, backed by tmux; do not replace this with a background `stream-json` client.
- User-level Claude hooks are installed only by explicit action; uninstall removes only AgentHub-owned entries.
- Permission handling is first-responder: AgentHub may act only after validating the exact session and current prompt.
- Accessibility for Desktop navigation is optional; ambiguity or UI drift degrades to app activation. Never best-effort click, paste, or submit.
- Cross-agent delivery is tiered: an idle verified AgentHub-managed CLI may receive direct input; external CLI and Desktop targets use bounded clipboard-and-jump only.
- CodexBar installation requires an explicit user action; AgentHub never installs software silently.
- The user requested transfer between agents for completion. The design and plans are approved — do not reopen product-design questions.

### Useful Memory
- Work happens in the worktree `.worktrees/agenthub-claude` on `codex/agenthub-claude`, branched from local `main` at `c44cf1c`. `.worktrees/` is gitignored.
- Existing Codex and OpenCode vertical slices are the pattern to follow for package, adapter, daemon, IPC, SwiftUI, and fixture tests.
- Fixtures load via `#filePath`-relative `Tests/Fixtures/<Provider>/<name>`; no SwiftPM resource declarations.
- `JSONEncoder.agentHub` uses ISO8601 dates — hand-written JSON fixtures must use date *strings*, not epoch numbers.
- Default tests must not submit a Claude prompt, consume quota, modify real Claude settings, inspect real transcripts, launch iTerm, request Accessibility, or invoke CodexBar.

## User Requirements
- Support Claude Code terminal and Claude Desktop in the AgentHub desktop app.
- List active Claude sessions, subagents, and background tasks.
- Centralize completion, permission, choice, and input notifications/requests when safely actionable.
- Click session rows to jump, with explicit degraded navigation when exact routing is unavailable.
- Transfer bounded output/context between Claude and other providers without manual copying where safe.
- Include Claude subscription usage and reset windows in this delivery.
- Preserve native Claude workflows and never auto-approve permissions.

## Completed
- VERIFIED: Design at `1461e4d`; Phase A/B plans at `c44cf1c`.
- VERIFIED: **Phase A — all 13 tasks** (`8a843f3` … `bfe3f72`), plus `DeliveryReconciler` (`82956e8`) and hook-installer wiring (`67038ac`). See the archived handoff `.agent/handoffs/2026-08-12T123800-phase-a-complete.md` for per-task detail.
- VERIFIED: **Phase B Task 1** (`5894c35`) — `QuotaWindow` gained optional `windowID`/`label`/`plan`; `id` includes `windowID` when present so a five-hour overall and five-hour model window no longer collide. Unnamed windows keep their exact legacy ID, and pre-change rows decode with the new fields nil.
- VERIFIED: **Phase B Task 2** (`a18892b`) — `CodexBarClaudeQuotaCollector` with app-helper-over-PATH discovery, the exact `usage --provider claude --source auto --format json --json-only --timeout 10` invocation, 1 MiB output cap, JSON-only parsing (never text/progress bars), partial-snapshot handling, and coarse `ClaudeQuotaError` categories that carry no stderr, account, or token text.
- VERIFIED: **Phase B Task 3** (`466302d`) — `CodexBarInstaller` (exact `brew install --cask codexbar`, Homebrew only from two absolute paths, no sudo/shell, validation after install), `ClaudeQuotaRefreshSchedule` (300s success; 60/120/240/480/900 backoff resetting after one good snapshot), and adapter wiring: `refreshQuota`, `startQuotaRefresh`/`stopQuotaRefresh`, `componentStatus(named:)`, quotas in `reconcile`, and `.installQuotaHelper`/`.refreshQuota` actions. Quota failure updates only the `codexbar` component and retains last-known windows.
- VERIFIED: **Phase B Task 4** (`3e775bc`) — `QuotaPresentation` (label-or-duration title, account·plan, staleness, `informsRecommendations`), quota strip using it, CodexBar install/refresh controls in Claude Settings, `DashboardViewModel.installCodexBar()`/`refreshClaudeQuota()`, two new `scripts/check.sh` gates, and README/development/claude-testing docs.
- VERIFIED: **`zsh scripts/check.sh` exits 0** at `3e775bc` (swift tests, plist/shell lint, xcodegen, Xcode app tests, helper/link/privacy/install gates).
- VERIFIED: `swift test` — 254 tests, 6 skipped (4 live Claude, 2 pre-existing), 0 failures. Xcode app tests: 34 passing.
- VERIFIED: The two new check.sh gates were proven non-vacuous — a stray `install --cask` outside `CodexBarInstaller` exits 1, and a `sudo` token in `Sources/AgentHubClaude` exits 1. The probe file was restored; the tree is clean.

## Current State
- Worktree clean at `3e775bc`; `main` untouched at `c44cf1c`. **20 commits ahead of `main`.**
- **Both Phase A and Phase B are complete and gate-verified.**
- **Nothing has been pushed and no PR exists.** The branch is local only.
- Next is code review and the integration decision — no implementation work remains in either plan.

### KNOWN FUNCTIONAL LIMIT — read before claiming Desktop navigation works
`App/AXClaudeAccessibilitySurface.snapshot(for:)` returns `nil` unconditionally: Claude Desktop exposes no native session ID or prompt fingerprint through Accessibility, so no window can be matched with certainty. Every Desktop request therefore degrades to activating Claude. This is deliberate and all executor safety rules are tested against fakes, but **Desktop auto-answer is not functional end to end**. Filling in `snapshot(for:)` is the only change needed if a reliable identification method is found.

### Quota caveat
CodexBar is **not installed** on this machine, so the collector has only ever run against fixtures and fake runners. The unavailable-source path is tested, but a live CodexBar JSON snapshot has never been parsed. Verify against a real install before claiming end-to-end quota display works.

## Decisions
- **Hooks + managed terminal + Desktop discovery**: one Claude adapter with user-level hooks, a managed tmux/iTerm runtime, and external CLI/Desktop discovery. Rejected: background `stream-json` as default; transcript scanning without hooks.
- **Capability-specific reliability**: managed CLI uses L2 validated control; external CLI/Desktop use L2 observation with L3 navigation fallbacks.
- **Two phases**: Phase A sessions verified before Phase B quota, so CodexBar absence/auth could never block core Claude support.
- **Quota isolated from sessions** (this session): quota actions route before hook actions in `configure`, and a quota failure touches only the `codexbar` component. A missing quota source must degrade visibly, never break sessions.
- **Last-known windows retained across failures** (this session): so the desktop shows stale data with a timestamp rather than blanking, per the plan's staleness rule.

## Git State
- worktree branch: `codex/agenthub-claude`, HEAD `3e775bc`, clean
- primary worktree: `main` at `c44cf1c`, only `.agent/` untracked
- commits added this session: `5894c35`, `a18892b`, `466302d`, `3e775bc` (plus `b98c14f`, `279eeda` earlier)
- nothing pushed; no remote branch

## Verification

### Full gate
- command: `zsh scripts/check.sh`
- status: PASS
- result: exit 0 at `3e775bc`.

### Full Swift package suite
- command: `swift test`
- status: PASS
- result: 254 tests, 6 skipped, 0 failures.

### Xcode app tests
- command: `xcodebuild -project AgentHub.xcodeproj -scheme AgentHubApp -destination 'platform=macOS' … test`
- status: PASS
- result: 34 tests, 0 failures.

### Task-level RED/GREEN
- status: PASS
- result: every Phase B task verified RED on missing symbols before implementation, then GREEN.

### Live CodexBar
- status: NOT-RUN
- result: CodexBar is not installed; only fixtures and fakes have exercised the collector.

## Failed Attempts

### CodeGraph project exploration
- tried: `codegraph_context` / `codegraph_status`.
- why it failed: SQLite `database is locked` (reported by the first agent; not retried since).
- retry only if: the lock is gone; the plans already contain exact file/interface mappings.

### Transient git index.lock
- tried: committing Phase A Task 2.
- why it failed: `index.lock` existed momentarily with no git process running; it cleared on its own and the retry succeeded. Do not delete lock files without confirming no git process is live.

## Remaining Work
1. Code review of the 20 commits on `codex/agenthub-claude` (`superpowers:requesting-code-review`), then address verified findings.
2. Integration decision via `superpowers:finishing-a-development-branch` — the branch is local and unpushed, so merging, PRing, or continuing are all still open.
3. Optional: verify quota end to end against a real CodexBar install (see the quota caveat).
4. Optional: if Desktop auto-answer is wanted, find a reliable Claude Desktop window identification method and fill in `AXClaudeAccessibilitySurface.snapshot(for:)`.
5. Do not push, merge, install CodexBar, alter real Claude settings, or request Accessibility without the relevant explicit workflow/user action.

## Recommended Next Step
Ask the user whether to run code review now or go straight to the integration decision. Both plans are complete and the full gate passes, so no implementation work is pending. Report the two caveats above honestly rather than describing Claude support as fully proven end to end.

### Practical notes for the next agent
- Swift 6 rejects `await` inside an `XCTAssert*`/`XCTUnwrap` autoclosure. Bind the actor read to a local first, then assert.
- Swift 6 rejects a `static let` of a non-`Sendable` type such as `ISO8601DateFormatter`; construct it locally (see `ClaudeTranscriptReader`).
- The hook decoder requires `session_id`, `transcript_path`, and `cwd` on every known event; minimal test payloads must include them.
- Adding a `DaemonCommand`/`DaemonReply` case breaks exhaustive switches in `Sources/AgentHubDaemon/DaemonAPI.swift` and `App/AppEnvironment.swift`.
- Adding a `ProviderConfigurationAction` case breaks exhaustive switches in `ClaudeAdapter.configure`.
- Adapter-specific errors follow the per-adapter enum convention (`ClaudeAdapterError`), not the shared `AdapterOperationError`.
- Never `await withCheckedContinuation` inside an actor while another actor method must resume it — that deadlocks. `ClaudeAdapter.awaitSessionStart` polls with `Task.sleep`.
- `Coordinator.start()` reconciles every adapter, so a fake adapter's default `AdapterSnapshot.fixture()` can collide with test-inserted rows. Start the coordinator only in tests that need it.

## Important Constraints
- Treat live repository state as authoritative and classify drift before edits.
- Preserve the unpushed design/plan commits and the existing worktree.
- No force push, history rewrite, destructive cleanup, silent package installation, real prompt consumption, credential access, or unsafe UI automation.
- Full transcripts and raw hook events must never be persisted; enforce current preview and handoff bounds.

## References
- `docs/superpowers/specs/2026-08-12-agenthub-claude-hybrid-design.md`
- `docs/superpowers/plans/2026-08-12-agenthub-claude-sessions.md` (complete)
- `docs/superpowers/plans/2026-08-12-agenthub-claude-quota.md` (complete)
- `Sources/AgentHubClaude/` (adapter, hooks, terminal, transcripts, quota collector, installer)
- `App/Features/Quota/QuotaPresentation.swift`
- `docs/claude-testing.md`
- `scripts/check.sh`
