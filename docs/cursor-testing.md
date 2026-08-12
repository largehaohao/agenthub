# Testing the Cursor integration

## What the default test run does

`zsh scripts/check.sh` and `swift test` use fixtures only. By design they never:

- submit a prompt to Cursor or consume subscription quota;
- read your real Cursor login session or `state.vscdb`;
- call the live Cursor usage API;
- modify your real `~/.cursor/hooks.json`;
- launch Cursor UI automation or answer tool permissions on your behalf.

Every Cursor test injects its own temporary hooks file, fixture envelopes, and
fake HTTP sessions, so a checkout on any machine produces the same result.

## Static gates in `scripts/check.sh`

Beyond the test suites, the script fails the build when:

- any embedded helper (`agenthubd`, `agenthub-claude-hook`,
  `agenthub-claude-statusline`, `agenthub-cursor-hook`) is missing or not
  executable;
- `AgentHubClaude` is not statically linked into the embedded `agenthubd`;
- Claude launch arguments are constructed anywhere except
  `ClaudeTerminalRuntime`, or a prompt is passed as a process argument;
- a permission-bypass flag appears anywhere in `Sources` or `App`;
- anything other than `CursorHookInstaller` mutates `~/.cursor/hooks.json`
  content;
- `accessToken` or `WorkosCursorSessionToken` string literals appear outside
  `CursorLoginSessionReader` and `CursorQuotaClient`.

## Hook installation and removal

AgentHub installs Cursor hooks only when you ask it to, from **Cursor Settings**
in the app. Installation merges AgentHub's entries into your existing
`~/.cursor/hooks.json` and leaves OpenIsland and other hooks untouched;
removal deletes only hook commands whose resolved path is exactly AgentHub's
helper.

The helper lives at:

```
~/Library/Application Support/AgentHub/bin/agenthub-cursor-hook
```

If the daemon is not running, decision hooks return `{"permission":"ask"}` and
observation hooks exit successfully, so Cursor is never blocked by AgentHub
being unavailable.

## Usage authorization

Cursor subscription usage is optional and requires an explicit **Authorize
Usage Reading** action in Cursor Settings. AgentHub then reads the local Cursor
login access token into process memory only, queries the dashboard usage API,
and stores normalized quota windows. **Revoke Usage Access** clears windows and
disables collection. The token is never written to SQLite, Keychain, logs, or
IPC snapshots.

Live-probed storage (no secrets in repo):

- database: `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
- ItemTable key: `cursorAuth/accessToken`
- usage endpoint: `GET https://cursor.com/api/usage-summary`
- cookie header: `WorkosCursorSessionToken=<token from state.vscdb>`

Default tests use fixture JSON shaped like the live response and never touch
those paths.

## Permission decisions

`beforeShellExecution` and `beforeMCPExecution` hooks create AgentHub permission
requests and block in `agenthub-cursor-hook` until you resolve them or a
25-second timeout returns `ask`. AgentHub never default-allows a tool permission.

## Known limitations

- There is no managed Cursor launch; handoffs are clipboard-and-jump only.
- Jump activates Cursor and opens a recorded workspace root when one is known.
- Usage refreshes only while authorization is enabled and the local login
  session remains valid.

## Verifying delivery end to end

The helpers resolve the daemon socket from Application Support. `AGENTHUB_SOCKET`
overrides that path so real delivery can be exercised against a throwaway daemon
instead of the user's live one. It exists for tests and local debugging; normal
runs leave it unset and use the real socket.

```bash
swift test --filter CursorVerticalSliceTests
swift test --filter CursorQuotaPrivacyTests
```

Those suites exercise Unix-socket ingest, permission await, and quota privacy
boundaries without reading real Cursor auth or calling live APIs.
