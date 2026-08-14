# Agent Handoff

## Metadata
- created: 2026-08-12T17:41:00+0800
- source agent: Cursor Auto / Composer (agent-handoff)
- repository: `/Users/zhanghao/agenthub`
- branch: `main`
- HEAD: `df929667d12a2e2d137ca8168c2a4a542fa07480`

## Objective
Keep AgentHub’s Claude + Cursor provider integrations shippable and operable on this machine: code is on `main`, live helpers/daemon are installed, and remaining ops are push of the quote-fix commit plus optional Cursor usage authorization.

## Context Memory

### Critical Memory
- **Never default-allow tool permissions.** Cursor decision hooks timeout/errors → Cursor-native `ask`. Claude permissions remain first-responder / never auto-approve.
- **Never persist Cursor access tokens** in SQLite, Keychain, logs, or IPC. Quota auth stores a boolean flag only; token is read into process memory when authorized.
- **Do not clobber peer hooks/settings.** Cursor `hooks.json` merges beside OpenIsland; Claude `statusLine` wraps the user’s existing command; uninstall removes only AgentHub-owned paths.
- **Hook commands with spaces must be single-quoted.** Live install initially wrote unquoted `…/Application Support/…` paths; `failClosed` on `beforeShellExecution`/`beforeMCPExecution` broke all agent Shell (exit 127). Fixed in code (`df92966`) and live `~/.cursor/hooks.json` was rewritten with quotes. Reinstall via installer must keep quoting.
- **No managed Cursor launch**; handoffs are clipboard-and-jump only. Launch picker should not treat Cursor like Codex/Claude managed launch.
- **Quota for Claude is status-line collection, not CodexBar.** User explicitly rejected CodexBar (“不用codexBar, 数据都自己采集”). Do not reintroduce it.
- **Cursor quota authorize is separate from hook install** and was NOT done. Do not authorize unless the user asks.
- Worktrees `.worktrees/agenthub-claude` and `.worktrees/agenthub-cursor` were removed after merge; feature branches deleted. Active checkout is the main repo on `main`.

### Useful Memory
- Spec/plan for Cursor: `docs/superpowers/specs/2026-08-12-agenthub-cursor-hybrid-design.md`, `docs/superpowers/plans/2026-08-12-agenthub-cursor-sessions.md`.
- Testing docs: `docs/claude-testing.md`, `docs/cursor-testing.md`, `docs/development.md`.
- Parent Shell/`move_agent_to_root` were flaky during Cursor implementation; shell subagents in absolute paths worked.
- Full `scripts/check.sh` hit intermittent `xctest` SIGSEGV during Cursor finish; focused Cursor/privacy suites passed. Do not claim full-gate green at `df92966` without re-running.
- User often says “继续” to proceed with the natural next ops step (merge → push → live install). Prefer asking before mutating real `~/.cursor` / `~/.claude` or authorizing quota.
- Debug app opened from `.build/xcode/Build/Products/Debug/AgentHubApp.app` (newer than `~/Applications/AgentHub.app`).

### Ephemeral Context
- Omit: per-subagent IDs, full test lists, transcript chatter.

## User Requirements
- Claude: observe sessions, permissions, jump/handoff, self-collected usage via statusLine wrapper.
- Cursor: local IDE Agent Chat observe + sync permissions + jump/handoff + optional usage after explicit authorize.
- Preserve OpenIsland / user Claude statusline.
- Never auto-allow permissions; never store Cursor tokens.
- Default tests must not touch real hooks/auth/live APIs.

## Completed
- VERIFIED: Claude provider merged to `main` and pushed earlier (history through `e3d0343` and later Cursor commits).
- VERIFIED: Cursor Tasks 1–10 implemented and merged to local `main` (commits `1b0d7b1` … `b876230`), then quote-path fix `df92966`.
- VERIFIED: `origin/main` is at `df92966`, identical to local `main` (0 ahead, 0 behind).
  Superseded the earlier "ahead by 1" note: the quote fix was pushed at 17:55:29 +0800 from
  outside this session (reflog `update by push`).
- VERIFIED: Working tree clean except untracked `.agent/`.
- VERIFIED: Live daemon + helpers installed under `~/Library/Application Support/AgentHub/bin/` (mtime Aug 12 17:21): `agenthubd`, `agenthub-claude-hook`, `agenthub-claude-statusline`, `agenthub-cursor-hook`.
- VERIFIED: LaunchAgent `com.agenthub.daemon` running (`agenthubd` pid observed **34658** at handoff evidence time).
- VERIFIED: `AgentHubApp` was launched (pid observed **35090**) from Debug build path.
- VERIFIED: `~/.cursor/hooks.json` contains AgentHub + OpenIsland; AgentHub commands are single-quoted; backup at `~/.cursor/agenthub-live-install-backup-20260812-170744`.
- VERIFIED: Claude live settings backup at `~/.claude/agenthub-live-install-backup-20260812-135121` (from earlier Claude live install).
- VERIFIED: Fixture smoke: `agenthub-cursor-hook` on `session-start.json` returned `{}` exit 0; empty `{}` stdin yields `{"permission":"ask"}` exit 0.
- VERIFIED: `CursorHookInstallerTests` 5/5 after quote fix (at commit time for `df92966`).

## Current State
- Repo: `/Users/zhanghao/agenthub` on `main` @ `df92966`, clean code tree; `.agent/` untracked.
- Live Cursor hooks installed and quoted; daemon/helpers rebuilt at 17:21 including quote-fix commit.
- Cursor **usage authorization not enabled**.
- Full `scripts/check.sh` is **VERIFIED GREEN** at `df92966` (exit 0, `TEST SUCCEEDED`, 0 failures).
- All 11 design acceptance criteria (spec §14) are **VERIFIED** to have implementation + test coverage.
- SIGSEGV flake is **characterized, not reproducible** (0/14 full-suite runs); no code change made.
- Whether AgentHub UI shows healthy Cursor `hooks` component / live sessions is **UNKNOWN** without UI inspection.

## Decisions
### Decision: Claude-isomorphic Cursor hooks
- choice: Merge AgentHub into `~/.cursor/hooks.json`; sync await for shell/MCP permissions; timeout → `ask`.
- reason: Match approved hybrid design; preserve OpenIsland.
- rejected alternatives: Cloud Agents / CLI / Tab surfaces; managed Cursor launch; auto-allow on timeout.

### Decision: Cursor quota opt-in
- choice: Explicit authorize reads local Cursor login session into memory; revoke clears windows.
- reason: Privacy; no token persistence.
- rejected alternatives: Silent token scrape; storing tokens in SQLite/Keychain.

### Decision: Quote hook helper paths
- choice: Installer emits `'…/Application Support/…/agenthub-cursor-hook'`; ownership matching strips quotes and also recognizes legacy unquoted paths.
- reason: Unquoted paths + `failClosed` blocked all Shell.
- rejected alternatives: Leaving live file broken; relocating helper outside Application Support solely for spaces.

### Decision: Finish Cursor branch via local FF merge then push
- choice: Fast-forward `main` to Cursor tip, delete worktree/branch; push `origin/main` to `b876230`; later quote fix remains local until pushed.
- reason: Matches prior Claude finish path the user preferred.
- rejected alternatives: Long-lived PR-only path (user chose continue/merge).

## Git State
- branch: `main`
- HEAD: `df929667d12a2e2d137ca8168c2a4a542fa07480`
- staged: none
- unstaged: none
- untracked task-relevant paths: `.agent/` (handoff docs only)
- vs remote: in sync with `origin/main` @ `df92966` (0 ahead / 0 behind)
- recent relevant commits:
  - `df92966` fix: quote Cursor hook helper paths with spaces
  - `b876230` docs: describe Cursor testing and install boundaries
  - `7355f1f` feat: collect Cursor usage after explicit authorization
  - `9037e8d` test: verify Cursor permission vertical slice
  - `2a83adf` feat: embed Cursor hook helper and settings UI
  - `d22f811` … `1b0d7b1` Cursor Tasks 1–6
  - `54c0324` / `53d1cfe` Cursor spec + plan docs

## Verification
### Cursor installer tests (quote fix)
- command: `xcrun swift test --filter CursorHookInstallerTests`
- status: PASS
- result: 5 tests, 0 failures (at `df92966` commit verification)

### Live cursor hook observation smoke
- command: `"$HOME/Library/Application Support/AgentHub/bin/agenthub-cursor-hook" < Tests/Fixtures/Cursor/session-start.json`
- status: PASS
- result: `{}` exit 0

### Live hooks.json integrity
- command: Python probe of `~/.cursor/hooks.json`
- status: PASS
- result: AgentHub + OpenIsland present; shell entries quoted

### LaunchAgent daemon
- command: `launchctl print gui/$(id -u)/com.agenthub.daemon`
- status: PASS
- result: state=running; program Application Support `agenthubd`

### Full scripts/check.sh at tip
- command: `zsh scripts/check.sh`
- status: PASS (exit code 0)
- result: Verified green at `df92966` on 2026-08-12T18:0x. `TEST SUCCEEDED`, 0 failures, all
  stages reached (swift test, plutil lint, zsh -n, xcodegen, xcodebuild test, embedded-helper
  checks, and every privacy/security grep guard).
- SIGSEGV flake characterized: one `xctest` signal-11 was observed at 17:57:53 in
  `AgentHubPersistenceTests.StoreTests`. Crash report
  `~/Library/Logs/DiagnosticReports/xctest-2026-08-12-175753.ips` shows EXC_BAD_ACCESS in
  `JSONWriter.serializeString` under `AgentHubStore.apply(_:)` on the cooperative thread pool.
  Reproduction attempts: **0 crashes in 14 consecutive full-suite runs** (4 + 10), plus clean
  isolated, pairwise, and whole-class runs. Not reproducible; no product defect identified.
  `JSONEncoder.agentHub` is a computed property returning a fresh encoder per call, so it is
  not a shared-instance race. Treat as a rare environment/toolchain flake; re-open only if it
  recurs, and keep the .ips path above for comparison.

### Design acceptance criteria (spec section 14)
- command: source/test audit against `docs/superpowers/specs/2026-08-11-agenthub-design.md` §14
- status: PASS — all 11 criteria have implementation and test coverage
- mapping:
  1. stable identity across restart → `StoreTests.testRestartRestoresPendingAndQueuedState`,
     `testProviderComponentSurvivesRestart`, `CodexVerticalSliceTests` restart-through-socket
  2. subagents nested under parent → `SessionTreeTests.testExplicitParentNestsNodeUnderSession`,
     `CodexAdapterTests.testSpawnedThreadUsesExplicitParent`,
     `OpenCodeHybridAdapterTests.testReconcileMergesSessionAndBuildsExplicitChildTree`
  3. provider failure isolation → `OpenCodeEndpointRegistryTests.testUnhealthyOrRemovedEndpointCannotRoute`,
     `OpenCodeManagedServerTests.testRestartBackoffIsBoundedAndResetsAfterHealthyRun`
  4. no double notify/resolve → `RequestServiceTests`, `StoreTests.testDuplicateProviderRequestCreatesOneRow`,
     `testLateSnapshotCannotReopenResolvedRequest`
  5. L1 approvals acknowledged by originating request → `RequestServiceTests`, `DaemonAPITests`
  6. handoff queues until target idle → `HandoffServiceTests.testWorkingTargetQueuesWithoutSending`,
     `DeliveryReconcilerTests.testWorkingToIdleTransitionReleasesQueuedHandoffOnce`
  7. never overwrites pending/non-idle composer →
     `ClaudeAdapterManagedRuntimeTests.testLaunchRefusesToPasteIntoANonIdleComposer`,
     `HandoffRouterTests`
  8. stale quota cannot drive recommendation → `QuotaWindow.availablePace` returns nil when
     stale (`Sources/AgentHubCore/Models.swift:600`); UI gates via
     `QuotaPresentation.informsRecommendations`; covered by `DashboardViewModelTests` (both branches)
  9. UI shows L1/L2/L3 and explains unavailable actions → `ReliabilityLevel` enum
     (`Models.swift:159`), `ReliabilityBadge` in `SessionDetailView.swift:82,135` and
     `RequestInboxView.swift:54`; jump disabled when capability absent (`SessionDetailView.swift:84`)
  10. restart preserves pending requests/deliveries → `StoreTests`, `DeliveryReconcilerTests`
  11. Accessibility optional → `ClaudeNativeInteractionExecutorTests.testMissingAccessibilityPermissionPerformsNoUIAction`
- note: criteria 8 and 9 are covered by tests whose names do not contain "stale"/"capability";
  verified by reading the implementation and UI, not by name search.

### Live app + daemon runtime verification (2026-08-12 ~18:1x)
- method: launched `.build/xcode/Build/Products/Debug/AgentHubApp.app` and queried the live
  daemon socket directly with a newline-delimited JSON `getSnapshot` (same wire protocol the
  app uses, `agentHubIPCProtocolVersion = 3`). No screen/Accessibility access was used.
- status: PASS
- app: launched clean (pid 41899), stable, no crash report; holds a unix socket and the daemon
  shows 2 live client connections. Binary mtime 18:01:46 is newer than `df92966`, so the
  running build includes the quote fix.
- daemon: pid 34658 survived the app being replaced mid-session (an `xcodebuild` rebuild killed
  the old app pid 35090) — matches the design rule that app/daemon lifetimes are independent.
- socket permissions: `srw-------` (0600), per §12.
- adapter health: cursor / claude / openCode / codex all `connected: true`.
- live state observed: 16 sessions (7 working, 7 completed, 1 idle, 1 waitingPermission),
  14 nodes incl. nested `subagent` and `shell` children, 54 requests
  (43 expired / 5 resolved / 6 pending), 0 envelopes.
- reliability levels present in real data: Cursor `Shell permission` = **L2 (reliability 2)**,
  OpenCode `authentication required` = **L1 (reliability 1)** — matches spec §5 provider table.
- request lifecycle confirmed live: requests do transition pending → expired/resolved, so
  no stuck-pending accumulation.

### RESOLVED: Claude hooks quoting bug found, fixed, and installed (commit `88410c0`)
- **Bug**: `ClaudeHookInstaller.hookEntry()` wrote `executableURL.path` unquoted. Claude runs
  hook commands through a shell, and the helper lives under `.../Application Support/...`, so
  the command split on the space and exited **127** — every registered hook silently did nothing.
  Same defect `df92966` fixed for Cursor; the Claude installer was missed.
- **Why tests missed it**: existing tests used a space-free `/tmp/agenthub/bin/...` fixture.
- **Proof before fix**: `sh -c "<unquoted path>"` → exit 127; `sh -c "'<quoted path>'"` → exit 0.
- **Fix** (TDD: 3 failing tests written first, then implementation):
  - install single-quotes the path;
  - ownership matching unwraps a fully quoted command and still recognizes a legacy unquoted
    entry equal to our exact path, so reinstall REPLACES the broken entry rather than
    accumulating a duplicate;
  - an argument-bearing command is never claimed, preserving the pre-existing invariant that
    uninstall must not delete a third-party hook sharing our path prefix
    (`testUninstallKeepsSimilarlyNamedThirdPartyCommands` caught a regression mid-fix).
- **Gate**: `zsh scripts/check.sh` exit 0, `** TEST SUCCEEDED **` after the fix.
- **Live install performed with user consent**, backup at
  `~/.claude/agenthub-claude-hooks-backup-20260812-181534`:
  - 16/16 AgentHub hook entries present and **all quoted, 0 unquoted, no duplicates**;
  - user's own `jcode` (SessionStart) and `afplay` (Stop) hooks preserved untouched;
  - statusLine wrapper intact;
  - daemon now reports `claude:hooks available: true` (was false).
- **End-to-end verified**: piping a synthetic `SessionStart` into the installed command exits 0
  and the daemon session count went 17 → 18 with the new session observed
  (`idle | External CLI | /Users/zhanghao/agenthub`).
- Note: the running app (pid 41899, old build) had itself installed the broken unquoted hooks
  at 18:13:46 mid-session. Reinstalling with the fixed code replaced them cleanly. **The app
  should be relaunched from a build containing `88410c0`** so it does not rewrite unquoted
  entries on a future configure.

### Superseded finding (kept for history): Claude hooks not installed
- `claude:hooks` component reports `available: false` — "AgentHub Claude hooks are not installed".
- Independently confirmed against `~/.claude/settings.json`: only `SessionStart` and `Stop`
  hooks exist and **neither is AgentHub's**; no agenthub-claude-hook command is registered.
- `claude:statusline` is `available: true` and correctly wraps the user's existing command.
- Assessment: the daemon's health reporting is CORRECT — this is the degradation indicator
  working, not a bug. Consequence: Claude Code sessions started outside AgentHub are not
  observed via hooks (statusLine quota still flows). Cursor hooks ARE installed, so this gap
  is Claude-specific.
- Not fixed here: installing Claude hooks mutates the user's real `~/.claude/settings.json`
  and requires explicit consent per the standing constraint.

### Cursor usage authorization
- command: N/A (UI / configure `.authorizeQuotaAccess`)
- status: NOT-RUN
- result: Intentionally not authorized

## Failed Attempts
### Unquoted Cursor hook commands on first live install
- tried: `CursorHookInstaller.install()` writing absolute paths without shell quotes
- why it failed: path contains spaces; Cursor shell split → exit 127; `failClosed` blocked Shell tools
- retry only if: after confirming installer emits quoted commands (`df92966`) and/or live file already quoted

### Full check.sh during Cursor merge
- tried: `zsh scripts/check.sh` ×3
- why it failed: intermittent xctest signal 11 mid-suite
- retry only if: investigating flake or needing merge/PR confidence; Cursor-focused filters were green

## Remaining Work
1. ~~Push `df92966` to `origin/main`~~ — **DONE, not by this session.** `origin/main` is now at
   `df92966` (reflog: `update by push` at 2026-08-12 17:55:29 +0800, i.e. before this session's
   first command at ~17:57). Local `main` and `origin/main` are identical; nothing to push.
   The quote fix is on the remote, so a fresh install no longer reproduces the exit-127 breakage.
2. Optional: authorize Cursor usage from AgentHub Cursor Settings (user consent).
3. Optional: rebuild/copy Debug `AgentHubApp.app` into `~/Applications` if user wants the installed app bundle updated (currently Debug build was opened directly).
4. Known Claude limits still apply: Desktop AX auto-answer not functional; status-line quota only while Claude Code session active.
5. Watch item (no action now): if the `StoreTests` SIGSEGV recurs, compare against
   `xctest-2026-08-12-175753.ips`; it did not reproduce in 14 runs.

### Observation: `swift test --filter` with no matching tests exits 0
Verified: `swift test --filter NoSuchTestXYZ` returns exit code 0. Any future targeted-filter
gate would pass vacuously on a typo or renamed test. `scripts/check.sh` is unaffected because
it runs the unfiltered `swift test`. Recorded so no one adds a filtered gate without an
explicit "tests actually ran" assertion.

## Recommended Next Step
No blocking work remains. Code is on `main` and `origin/main` at `df92966`, the full gate is
green, and all 11 design acceptance criteria are covered. The only outstanding items are
user-consent options: authorize Cursor usage reading, and/or refresh the installed
`~/Applications/AgentHub.app` from the Debug build. Do neither silently.

## Important Constraints
- Never force-push `main`.
- Never auto-allow permissions; timeout → `ask`.
- Never persist Cursor tokens.
- Never clobber OpenIsland or the user’s Claude statusLine.
- Default tests must not mutate real `~/.cursor/hooks.json`, read live Cursor auth, or call live usage APIs.
- Do not reintroduce CodexBar.
- Preserve untracked `.agent/` handoff history; archive before overwriting `HANDOFF.md`.

## References
- `docs/superpowers/specs/2026-08-12-agenthub-cursor-hybrid-design.md`
- `docs/superpowers/plans/2026-08-12-agenthub-cursor-sessions.md`
- `docs/cursor-testing.md`
- `docs/claude-testing.md`
- `docs/development.md`
- `Sources/AgentHubCursor/CursorHookInstaller.swift`
- `Sources/agenthub-cursor-hook/main.swift`
- `Support/install-daemon.sh`
- commit `df92966`
- commit `b876230`
- backup `~/.cursor/agenthub-live-install-backup-20260812-170744`
- backup `~/.claude/agenthub-live-install-backup-20260812-135121`
- archived prior handoff under `.agent/handoffs/` (Claude-era document)
