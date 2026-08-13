# Agent Handoff

## Metadata
- created: 2026-08-12T13:45:00+0800
- source agent: `claude-opus-5`
- repository: `/Users/zhanghao/agenthub`
- implementation worktree: `/Users/zhanghao/agenthub/.worktrees/agenthub-claude`
- branch: `codex/agenthub-claude`
- HEAD: `e3d0343` (worktree, clean); `main` remains at `c44cf1c`

## Objective
Deliver the approved AgentHub Claude provider integration: visible managed Claude Code CLI sessions, external CLI and Claude Desktop discovery, unified lifecycle/subagents/requests, safe jump and handoff behavior, and Claude subscription usage.

**Both approved plans are implemented. The branch is feature-complete and gate-green; nothing is pushed.**

## Context Memory

### Critical Memory
- **Quota source was changed by explicit user instruction.** On 2026-08-12 the user said "不用codexBar, 数据都自己采集" (don't use CodexBar, collect the data ourselves). CodexBar was removed entirely and replaced by a status-line collector. Do not reintroduce CodexBar or any third-party quota helper.
- The quota contract was verified inside the Claude Code 2.1.228 binary: Claude pipes `rate_limits: { five_hour: {used_percentage, resets_at}, seven_day: {...} }` to the configured `statusLine` command. These are real Anthropic-reported percentages, not estimates.
- **Claude Code supports only ONE statusLine command, and the user already has their own** (`sh /Users/zhanghao/.claude/statusline-command.sh`). The installer therefore *wraps* rather than replaces, and uninstall restores the original. Never clobber it.
- Rejected quota alternative: summing tokens from `~/.claude/projects/*.jsonl`. Those transcripts carry per-message token counts but **no** rate-limit or plan-allowance fields, so any percentage would have been guesswork.
- Managed Claude tasks open as a visible native TUI in iTerm backed by tmux; do not replace this with a background `stream-json` client.
- Permission handling is first-responder: AgentHub acts only after revalidating the exact session and current prompt. Never auto-approve.
- Accessibility for Desktop navigation is optional; ambiguity or UI drift degrades to app activation. Never best-effort click, paste, or submit.
- Cross-agent delivery is tiered: an idle verified AgentHub-managed CLI may receive direct input; external CLI and Desktop targets use bounded clipboard-and-jump only.
- The user has repeatedly asked to continue autonomously ("继续"). They value verified evidence over optimistic claims — every completion claim in this file was re-run at `e3d0343`.

### Useful Memory
- Work happens in the worktree `.worktrees/agenthub-claude` on `codex/agenthub-claude`, branched from local `main` at `c44cf1c`. `.worktrees/` is gitignored.
- Codex and OpenCode vertical slices are the pattern for package, adapter, daemon, IPC, SwiftUI, and fixture tests.
- Fixtures load via `#filePath`-relative `Tests/Fixtures/<Provider>/<name>`; no SwiftPM resource declarations.
- `JSONEncoder.agentHub` uses ISO8601 dates — hand-written JSON fixtures must use date *strings*, not epoch numbers.
- Default tests must not submit a Claude prompt, consume quota, modify real Claude settings, inspect real transcripts, launch iTerm, or request Accessibility.

## User Requirements
- Support Claude Code terminal and Claude Desktop in the AgentHub desktop app.
- List active Claude sessions, subagents, and background tasks.
- Centralize completion, permission, choice, and input notifications/requests when safely actionable.
- Click session rows to jump, with explicit degraded navigation when exact routing is unavailable.
- Transfer bounded output/context between Claude and other providers without manual copying where safe.
- Show Claude subscription usage and reset windows, collected by AgentHub itself.
- Preserve native Claude workflows and never auto-approve permissions.

## Completed
- VERIFIED: **Phase A — all 13 tasks** (`8a843f3` … `bfe3f72`), plus `DeliveryReconciler` (`82956e8`) and hook-installer wiring (`67038ac`). Per-task detail is in `.agent/handoffs/2026-08-12T123800-phase-a-complete.md`.
- VERIFIED: **Quota window labelling** (`5894c35`) — `QuotaWindow` gained optional `windowID`/`label`/`plan`; `id` includes `windowID` so same-duration windows cannot collide. Unnamed windows keep their exact legacy ID and pre-change rows decode with new fields nil.
- VERIFIED: **Status-line quota collection** (`43fad2c`) — replaced CodexBar. Adds `ClaudeStatusLineQuota` (decoder), `ClaudeStatusLineInstaller` (wrap/unwrap), `ClaudeSettingsStore` (shared atomic settings I/O, now also used by `ClaudeHookInstaller`), and the `agenthub-claude-statusline` helper. Deleted `CodexBarClaudeQuotaCollector`, `CodexBarInstaller`, `ClaudeQuotaRefreshSchedule` and their tests — the polling/backoff model is gone because status-line data is pushed.
- VERIFIED: **End-to-end delivery** (`e3d0343`) — live tests execute the generated wrapper through `/bin/sh` and run the packaged reporter binary against a real Unix socket and daemon server. Added `ClaudeHelperSocket` with the `AGENTHUB_SOCKET` override, because macOS derives Application Support from the user record rather than `HOME`, so delivery was previously untestable except against the user's live daemon.
- VERIFIED at `e3d0343`: `zsh scripts/check.sh` exits **0**.
- VERIFIED at `e3d0343`: `swift test` — **261 tests, 10 skipped, 0 failures**. Xcode app tests — **35 tests, 0 failures**.
- VERIFIED at `e3d0343`: `AGENTHUB_LIVE_CLAUDE_SMOKE=1 swift test --filter 'LiveClaudeTests|ClaudeStatusLineDeliveryTests'` — **8 tests, 1 skipped, 0 failures** (the skipped one is the quota-consuming prompt test).
- VERIFIED: New `check.sh` gates were proven non-vacuous by deliberate violation, then restored: a stray `brew`/`--cask`/`sudo` in `Sources`/`App` exits 1, and a `"statusLine"` write outside `ClaudeStatusLineInstaller` exits 1. The `LiveClaudeTests` wrapper test and the socket-delivery test were each shown to FAIL when the wrapper or the send was broken.
- VERIFIED: Against a **copy** of the user's real `~/.claude/settings.json` (which contains a live statusLine plus `SessionStart`/`Stop` hooks), install preserved the user's command inside the wrapper, kept both hooks and all 12 keys, and uninstall produced a semantically identical file.
- VERIFIED: The user's real statusline rendered **byte-identically** through the wrapper (same colors, git state, `ctx:42.0k/200k(21%)`, `5h:34% 7d:12%`), while AgentHub simultaneously received the identical payload over a real socket from one invocation.

## Current State
- Worktree clean at `e3d0343`; `main` untouched at `c44cf1c`; branch is **22 commits ahead**.
- **Nothing pushed, no PR, no remote branch.**
- **The user's `~/.claude/settings.json` was never modified** — mtime is `Aug 12 11:02:19 2026`, predating all of this session's work, and it contains no `agenthub-statusline` marker. All settings testing used copies.
- No implementation work remains in either plan. The open decisions are code review and integration.

### KNOWN LIMIT 1 — Desktop auto-answer is not functional
`App/AXClaudeAccessibilitySurface.swift:45` `snapshot(for:)` returns `nil` unconditionally: Claude Desktop exposes no native session ID or prompt fingerprint through Accessibility, so no window can be matched with certainty. Every Desktop request degrades to activating Claude. This is deliberate and its safety rules are tested against fakes, but **do not describe Desktop auto-answer as working**. Filling in `snapshot(for:)` is the only change needed if a reliable identification method is found.

### KNOWN LIMIT 2 — no real Claude session has driven the reporter
Everything up to the boundary is verified (wrapper through `sh`, reporter binary to a real socket/daemon, installer against a copy of the real settings). What has **not** happened: installing the new build and adding AgentHub to the user's real `settings.json`, then letting a live Claude Code session write through it. That requires two user-machine mutations and is the user's call.

### KNOWN LIMIT 3 — installed daemon is stale
The daemon currently running from `~/Library/Application Support/AgentHub/bin/agenthubd` is dated `Aug 11 21:56` and contains **zero** occurrences of `ingestProviderHook`. It predates protocol v3 and all Claude work, so it cannot validate any of this. Any live end-to-end test needs the new build installed first.

### Status-line coverage caveat
The status line fires only while a Claude Code session is active, so usage refreshes when Claude is used rather than on a timer, and Claude Desktop is not covered. This is inherent to the source and is documented in `docs/claude-testing.md`.

## Decisions
- **Collect usage ourselves via statusLine, not CodexBar** (user instruction). Real `rate_limits` percentages plus reset times; no third-party app, no package install, no polling loop.
- **Wrap rather than replace the statusLine.** Claude Code allows one status line and the user has one. AgentHub's reporter is fed the payload first, writes nothing to stdout, then the user's command receives identical bytes and owns the display. A reporter failure is swallowed. Uninstall restores the original command, or removes the key only when AgentHub introduced it.
- **Reuse the hook envelope transport for status-line payloads.** No new IPC command; the adapter distinguishes them by the absence of `hook_event_name`.
- **Absent data stays absent.** A window is emitted only when both `used_percentage` and `resets_at` are valid — never a fabricated 0%. An empty report keeps the last real reading rather than blanking it.
- **`AGENTHUB_SOCKET` override added for testability**, because Application Support is not `HOME`-redirectable on macOS. Unset in normal runs.
- **Shared `ClaudeSettingsStore`** extracted so parse-copy-validate-atomic-replace exists in exactly one place for both installers.

## Git State
- worktree branch: `codex/agenthub-claude`, HEAD `e3d0343`, clean (no staged/unstaged/untracked)
- primary worktree: `main` at `c44cf1c`, only `.agent/` untracked
- 22 commits ahead of `main`; nothing pushed
- commits this session: `5894c35`, `a18892b`, `466302d`, `3e775bc`, `43fad2c`, `e3d0343` (note: `a18892b`/`466302d` introduced CodexBar and `43fad2c` removed it — history retains both, which is intentional)

## Verification
All of the following were run at `e3d0343` for this handoff, not recalled:

| Check | Command | Result |
|---|---|---|
| Full gate | `zsh scripts/check.sh` | PASS (exit 0) |
| Package tests | `swift test` | PASS — 261 tests, 10 skipped, 0 failures |
| App tests | via check.sh xcodebuild | PASS — 35 tests, 0 failures |
| Live smoke | `AGENTHUB_LIVE_CLAUDE_SMOKE=1 swift test --filter 'LiveClaudeTests\|ClaudeStatusLineDeliveryTests'` | PASS — 8 tests, 1 skipped, 0 failures |
| User settings untouched | `stat` + marker grep on `~/.claude/settings.json` | PASS — mtime 11:02:19, no marker |

Not run: any test that submits a Claude prompt (`AGENTHUB_LIVE_CLAUDE_PROMPT=1`), and any live install into the user's real settings or daemon.

## Failed Attempts

### Redirecting the helper socket with `HOME`
- tried: `HOME=<tmp> swift` to make `FileManager.applicationSupportDirectory` resolve into a sandbox.
- why it failed: macOS derives that path from the user record, so it returned the real `/Users/zhanghao/Library/Application Support` regardless.
- resolution: added `ClaudeHelperSocket` + `AGENTHUB_SOCKET`. Do not retry the `HOME` approach.

### CodeGraph project exploration
- tried: `codegraph_context` / `codegraph_status`.
- why it failed: SQLite `database is locked` (reported by the first agent; not retried since).
- retry only if the lock is gone; the plans already contain exact file/interface mappings.

### Transient git index.lock
- tried: committing an early task.
- why it failed: `index.lock` existed momentarily with no git process running; it cleared on its own and the retry succeeded. Do not delete lock files without first confirming no git process is live.

## Remaining Work
1. **Code review** of the 22 commits (`superpowers:requesting-code-review`), then address verified findings.
2. **Integration decision** via `superpowers:finishing-a-development-branch` — local and unpushed, so merge/PR/continue are all open.
3. Optional, needs user consent (two machine mutations): install the new build's daemon + reporter, add AgentHub to the real `~/.claude/settings.json`, and confirm a live Claude Code session populates the usage strip. This closes KNOWN LIMIT 2 and 3.
4. Optional: if Desktop auto-answer is wanted, find a reliable Claude Desktop window identification method and implement `AXClaudeAccessibilitySurface.snapshot(for:)` (KNOWN LIMIT 1).
5. Do not push, merge, install anything system-wide, alter real Claude settings, or request Accessibility without the relevant explicit workflow or user approval.

## Recommended Next Step
Ask the user whether to (a) run code review now, (b) go to the integration decision, or (c) do the live install to close KNOWN LIMIT 2/3. Do not start (c) without explicit approval — it modifies `~/.claude/settings.json` and replaces the installed daemon. When reporting status, state the three KNOWN LIMITs plainly rather than describing Claude support as fully proven end to end.

### Practical notes for the next agent
- Swift 6 rejects `await` inside an `XCTAssert*`/`XCTUnwrap` autoclosure. Bind the actor read to a local first, then assert.
- Swift 6 rejects a `static let` of a non-`Sendable` type such as `ISO8601DateFormatter`; construct it locally.
- The hook decoder requires `session_id`, `transcript_path`, and `cwd` on every known event; minimal test payloads must include them. Status-line payloads have none of these and are routed by the absence of `hook_event_name`.
- Adding a `DaemonCommand`/`DaemonReply` case breaks exhaustive switches in `Sources/AgentHubDaemon/DaemonAPI.swift` and `App/AppEnvironment.swift`; a `ProviderConfigurationAction` case breaks `ClaudeAdapter.configure`.
- Adapter-specific errors use per-adapter enums (`ClaudeAdapterError`), not the shared `AdapterOperationError`.
- Never `await withCheckedContinuation` inside an actor while another actor method must resume it — that deadlocks. `ClaudeAdapter.awaitSessionStart` polls with `Task.sleep`.
- `Coordinator.start()` reconciles every adapter, so a fake adapter's default `AdapterSnapshot.fixture()` can collide with test-inserted rows. Start the coordinator only in tests that need it.
- `scripts/check.sh` forbids `brew`/`--cask`/`sudo` anywhere in `Sources`/`App`, and forbids writing `"statusLine"` outside `ClaudeStatusLineInstaller`.

## Important Constraints
- Treat live repository state as authoritative and classify drift before edits.
- Preserve the unpushed commits and the existing worktree; branch from local `main`, not `origin/main`.
- Each task: RED → verify RED → GREEN → verify GREEN → task-scoped commit.
- No force push, history rewrite, destructive cleanup, silent package installation, real prompt consumption, credential access, or unsafe UI automation.
- Full transcripts and raw hook events must never be persisted; enforce current preview and handoff bounds.
- The status-line payload carries prompt-adjacent context (cwd, transcript path, context window); only `rate_limits` may be read. There is a test asserting none of the rest survives into quota state.

## References
- `docs/superpowers/specs/2026-08-12-agenthub-claude-hybrid-design.md`
- `docs/superpowers/plans/2026-08-12-agenthub-claude-sessions.md` (complete)
- `docs/superpowers/plans/2026-08-12-agenthub-claude-quota.md` (**marked SUPERSEDED** — specified CodexBar; retained for history)
- `docs/claude-testing.md` (implemented quota behavior, `AGENTHUB_SOCKET`, live commands)
- `Sources/AgentHubClaude/ClaudeStatusLineQuota.swift`, `ClaudeStatusLineInstaller.swift`, `ClaudeSettingsStore.swift`, `ClaudeHelperSocket.swift`
- `Sources/agenthub-claude-statusline/main.swift`
- `Tests/AgentHubIPCTests/ClaudeStatusLineDeliveryTests.swift`
- `App/AXClaudeAccessibilitySurface.swift:45` (the Desktop limitation)
- `.agent/handoffs/` (three archived predecessors)
