# AgentHub

AgentHub is a native macOS control center for coding-agent sessions. It uses a
user-scoped background daemon and a local Unix socket, so session state and
requests remain available when the window is closed.

The current foundation supports Codex end to end:

- discover and launch Codex sessions, including visible subagents;
- show session status, pending approval/input requests, and quota windows;
- resolve Codex requests and jump to a session detail;
- deliver a bounded, attributed handoff between managed sessions;
- persist normalized state in a local SQLite database and reconnect after restart.

Claude Code, Cursor, OpenCode, cross-app deep links, and normalized quota
forecasting are planned provider slices, not part of this foundation build yet.

## Requirements

- macOS 14 or newer
- Xcode 16 or newer with Swift 6
- XcodeGen 2.45.4 or newer
- a logged-in `codex` CLI available on `PATH`

## Build and verify

```bash
./scripts/check.sh
```

The ordinary test gate uses scripted Codex transport. The test that creates a
real Codex thread is opt-in and remains skipped by default.

For build, launch, installation, service inspection, fixture mode, live testing,
privacy, and uninstall commands, see [Development and operations](docs/development.md).

The approved product design and implementation plans are under
[`docs/superpowers/`](docs/superpowers/).
