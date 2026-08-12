# Testing the Claude integration

## What the default test run does

`zsh scripts/check.sh` and `swift test` use fixtures only. By design they never:

- submit a prompt to Claude or consume subscription quota;
- read your real Claude transcripts under `~/.claude`;
- modify your real `~/.claude/settings.json`;
- launch iTerm or tmux;
- request or rely on macOS Accessibility permission.

Every Claude test injects its own temporary settings file, fixture screens, and
fake terminal, so a checkout on any machine produces the same result.

## Static gates in `scripts/check.sh`

Beyond the test suites, the script fails the build when:

- either embedded helper (`agenthubd`, `agenthub-claude-hook`) is missing or not
  executable;
- `AgentHubClaude` is not statically linked into the embedded `agenthubd`;
- Claude launch arguments are constructed anywhere except
  `ClaudeTerminalRuntime`, or a prompt is passed as a process argument;
- a permission-bypass flag appears anywhere in `Sources` or `App`.

## Opt-in live checks

Two environment flags enable checks against the Claude on your machine. Both are
skipped unless explicitly set.

### `AGENTHUB_LIVE_CLAUDE_SMOKE=1`

Non-destructive compatibility probes. **Does not submit a prompt** and does not
consume quota:

```bash
AGENTHUB_LIVE_CLAUDE_SMOKE=1 swift test --filter LiveClaudeTests
```

It runs `claude --version`, validates hook install/uninstall against a temporary
settings file, and probes tmux capabilities.

### `AGENTHUB_LIVE_CLAUDE_PROMPT=1`

**Consumes Claude subscription quota.** It starts a managed session and submits
one short prompt. Keep it separate from the smoke flag so it can never run by
accident:

```bash
AGENTHUB_LIVE_CLAUDE_PROMPT=1 swift test --filter LiveClaudeTests
```

## Hook installation and removal

AgentHub installs hooks only when you ask it to, from **Claude Settings** in the
app. Installation merges AgentHub's entries into your existing user settings and
leaves every other key untouched; removal deletes only hook commands whose
resolved path is exactly AgentHub's helper.

The helper lives at:

```
~/Library/Application Support/AgentHub/bin/agenthub-claude-hook
```

If the daemon is not running, the helper exits immediately and successfully, so
Claude is never blocked or slowed by AgentHub being unavailable.

## Requirements for managed sessions

Managed Claude sessions need `claude`, `tmux`, and iTerm. Without them, Claude
sessions you start yourself are still discovered through hooks; only managed
launch is unavailable. The Claude Settings sheet shows each component's state.

## Known limitation: Claude Desktop navigation

Claude Desktop does not expose a native session ID or a prompt fingerprint
through Accessibility. AgentHub therefore cannot prove which Desktop window
holds a given request, and **always degrades to activating Claude** rather than
acting on a window it cannot verify. Answering a Desktop request from AgentHub
is not available; use the Claude window AgentHub brings forward.

## Claude subscription usage

Usage comes from CodexBar's machine-readable CLI, discovered first at
`/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI` and then on `PATH`.
AgentHub runs exactly:

```
codexbar usage --provider claude --source auto --format json --json-only --timeout 10
```

Only JSON is consumed — the human-readable cards and progress bars are never
parsed, so a cosmetic CodexBar change cannot corrupt AgentHub's data.

Installation happens only from **Install CodexBar** in Claude Settings, which
runs `brew install --cask codexbar` with an exact argument array and no shell.
Homebrew is accepted only from `/opt/homebrew/bin/brew` or `/usr/local/bin/brew`,
and `sudo` is never used.

The refresh loop polls every 5 minutes and backs off 1, 2, 4, 8, then 15 minutes
after failures, resetting after one valid snapshot. A failure updates only the
`codexbar` component: sessions, requests, jumps, and handoffs are unaffected,
and the last known windows are kept so they can be shown as stale rather than
disappearing.

Source errors are reported only as coarse categories (unavailable, timeout,
authentication required, malformed, failed). CodexBar's stderr text, account
identifiers, and tokens are never stored or displayed. Authentication is
repaired in CodexBar itself, in a foreground flow the user initiates.

Default tests use fixtures and fake runners; they never invoke CodexBar, reach
the network, or consume quota.
