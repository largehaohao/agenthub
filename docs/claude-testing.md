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

Usage comes from Claude Code itself. Claude Code pipes a JSON payload to the
configured `statusLine` command, and that payload carries the real limits:

```
rate_limits: {
  five_hour: { used_percentage, resets_at },
  seven_day: { used_percentage, resets_at }
}
```

Nothing is estimated from token counts, and no third-party app is involved.

Claude Code supports only one status line, so **Install Usage Reporter** wraps
rather than replaces. AgentHub's reporter is fed the payload first, writes
nothing to stdout, and then the user's own command receives the identical bytes
and still owns the display. A reporter failure is swallowed so the status line
keeps working. Removing restores the original command byte-for-byte, or removes
the key entirely when AgentHub introduced it. A status line AgentHub does not
own is never modified.

The reporter lives at:

```
~/Library/Application Support/AgentHub/bin/agenthub-claude-statusline
```

Only `rate_limits` is read. The prompt, transcript path, and context-window
detail in the payload are never stored. A window is emitted only when both its
percentage and reset time are valid: absent data stays absent rather than
displaying a fabricated 0%.

Known limits: the status line fires only while a Claude Code session is active,
so usage refreshes when you use Claude rather than on a timer, and Claude
Desktop is not covered.

Default tests use fixtures only and never invoke Claude or write a real status
line.
