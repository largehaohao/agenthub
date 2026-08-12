# AgentHub

AgentHub is a native macOS control center for coding-agent sessions. It uses a
user-scoped background daemon and a local Unix socket, so session state and
requests remain available when the window is closed.

The current desktop slice supports Codex, OpenCode, and Claude end to end:

- discover and launch Codex sessions, including visible subagents;
- show session status, pending approval/input requests, and quota windows;
- resolve Codex requests and jump to a session detail;
- deliver a bounded, attributed handoff between managed sessions;
- persist normalized state in a local SQLite database and reconnect after restart.
- discover OpenCode Desktop and terminal servers, or attach a loopback server manually;
- launch managed OpenCode sessions and merge duplicate native sessions across surfaces;
- handle OpenCode permissions, ordered questions, native jumps, and cross-provider handoffs;
- store OpenCode passwords in Keychain while sending only opaque references over IPC.
- observe Claude Code CLI and Claude Desktop sessions through user-scoped hooks
  you install explicitly;
- launch managed Claude sessions as a visible tmux-backed iTerm terminal, with
  the initial prompt delivered through a paste buffer rather than process
  arguments;
- surface Claude permissions, questions, subagents, and background tasks, and
  answer them only after revalidating the exact live prompt.

A Cursor provider slice is planned. OpenCode Go does not expose a supported
quota source yet, so AgentHub displays that limitation explicitly instead of
estimating a balance. Claude Desktop does not expose a session identifier
through Accessibility, so Desktop rows activate Claude rather than answering a
window AgentHub cannot verify.

## Requirements

- macOS 14 or newer
- Xcode 16 or newer with Swift 6
- XcodeGen 2.45.4 or newer
- a logged-in `codex` CLI available on `PATH`
- OpenCode 1.18.x on `PATH` for OpenCode discovery or managed launch
- Claude Code 2.1.x, plus `tmux` and iTerm for managed Claude sessions

## Build and verify

```bash
./scripts/check.sh
```

The ordinary test gate uses scripted Codex transport. The test that creates a
real Codex thread is opt-in and remains skipped by default.

The OpenCode live compatibility test performs only isolated session CRUD and
process-owned socket discovery; it never sends a model prompt. See
[OpenCode testing](docs/opencode-testing.md) for the opt-in command and privacy
boundaries.

Claude tests use fixtures only: they never submit a prompt, read real
transcripts, or modify your Claude settings. See
[Claude testing](docs/claude-testing.md) for the opt-in flags and the hook
install/uninstall behavior.

For build, launch, installation, service inspection, fixture mode, live testing,
privacy, and uninstall commands, see [Development and operations](docs/development.md).

The approved product design and implementation plans are under
[`docs/superpowers/`](docs/superpowers/).
