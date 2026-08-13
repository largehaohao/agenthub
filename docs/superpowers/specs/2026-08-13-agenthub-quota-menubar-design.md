# AgentHub Quota Menu Bar

**Status:** Approved
**Date:** 2026-08-13
**Supersedes:** `2026-08-13-agenthub-desktop-session-convergence-design.md`, and the
session, request, and handoff scope of `2026-08-11-agenthub-design.md`

## 1. Context

AgentHub set out to be a control centre for every coding agent on the machine:
sessions, approvals, handoff, and quota. Session management is the part that did
not survive contact with the providers.

- Claude Desktop cannot be observed at all. It spawns no agent process, keeps no
  enumerable conversation index, and its conversations are chat threads with no
  runtime state.
- Codex Desktop threads are not reachable. ChatGPT Desktop runs its own
  `codex app-server` over stdio with its parent, and a separately spawned server
  returns a different, mostly historical slice: seven threads, all
  `status: notLoaded`, while sixty-six Codex Desktop transcripts sit on disk
  unlisted. ChatGPT Desktop does listen on `~/.codex/ipc/ipc.sock`, but it
  closes connections that do not complete a handshake we do not know.
- Only Cursor produces live desktop sessions, through hooks it lets us install.

One provider out of three is not a session product. Quota, by contrast, works
for all four providers and is the part that has been genuinely useful.

This design keeps the part that works and deletes the rest. AgentHub becomes a
menu bar panel that shows subscription usage across Claude, Codex, Cursor, and
OpenCode.

## 2. Goals and non-goals

### Goals

- Show current usage for all four providers, at a glance, from the menu bar.
- Make the numbers the dominant visual element.
- Stay resident and refresh on its own.
- Reduce the codebase to what one person can hold in their head.

### Non-goals

- Sessions, subagents, background tasks.
- Permission requests and approvals.
- Cross-agent handoff.
- Provider hooks of any kind.
- History, trends, or alerting. The panel shows current state only.

## 3. Architecture

A single SwiftUI application. No daemon, no IPC, no database.

The daemon existed to keep observing while the window was closed. A menu bar
application is always resident, so it does that job by being what it is.

```
AgentHubApp  (LSUIElement, NSStatusItem)
    ├── AgentHubQuota     four readers + QuotaWindow
    └── AgentHubSecurity  Keychain access
```

Three modules, down from fourteen.

### Deleted

`agenthubd`, `AgentHubIPC`, `AgentHubPersistence`, `AgentHubDaemon`, every
adapter, every hook installer, the `agenthub-claude-hook` and
`agenthub-claude-statusline` executables, the session/node/request models,
handoff, the LaunchAgent, and the daemon install scripts.

## 4. Quota sources

All four already work and carry tests; this design moves them, it does not
rewrite them.

| Provider | Source | Credential |
|---|---|---|
| Claude | `GET api.anthropic.com/api/oauth/usage` | Keychain OAuth, read per request |
| Codex | spawned `codex app-server`, `account/rateLimits/read` | `~/.codex/auth.json` |
| Cursor | `GET cursor.com/api/usage-summary` | `state.vscdb` token as `<sub>::<jwt>` cookie |
| OpenCode | `GET opencode.ai/zen/go/v1/usage` | `~/.local/share/opencode/auth.json` |

### Credential rule

Unchanged and non-negotiable: a token is read at the moment of the request,
lives in memory only for the length of that request, and is never written to
disk, a log, or a window. The `check.sh` guard that enforces this survives the
rewrite.

### Codex subprocess

Codex is the only source needing a subprocess. Spawning `codex app-server` for
one call, every fifteen minutes, is accepted: it returns live numbers, where the
local alternative (`~/.codex/sessions/`) is only as fresh as the last Codex run.

### Refresh

Every fifteen minutes, inside the fifteen-minute staleness threshold; on hover
when the data is already stale; and on demand from the pinned panel. A failed
refresh keeps the previous reading rather than blanking the panel.

## 5. Interaction

- **Hover** over the status item, after a ~0.3s delay, shows a non-activating
  panel. The delay stops it firing when the pointer sweeps across the menu bar.
- **Mouse out** hides it.
- **Click** pins it, so refresh and Settings can be used.
- **Escape** or a click outside dismisses a pinned panel.
- **A configurable global hotkey** shows it pinned.

Settings — hotkey binding and Cursor usage authorisation — live in a standard
Settings window, reachable from the pinned panel and ⌘,.

## 6. Visual design

The numbers are the point, so they get the weight.

Each provider is one row: the provider name in its accent colour (Claude
orange, Codex green, Cursor blue, OpenCode purple), then for each window a
percentage set large (~28pt, semibold, **tabular figures** so digits do not
jitter between refreshes), a slim progress bar beneath it, and the reset time in
small secondary text.

Naming and ordering carry over unchanged: windows are named by duration (`5h`,
`7d`, `30d`); windows that share a duration keep the provider's own label
(Cursor's `API` / `Auto` / `Total`); ties order by window id so rows never
reshuffle. `STALE` and `ENDED` badges keep their current meaning.

The status item itself stays an icon. Rendering a number there was considered
and rejected: it competes with the menu bar's own density.

## 7. User-visible consequences

- **Login Items.** Removing the LaunchAgent means the app no longer starts
  itself. It must be added to Login Items to stay resident. The uninstall
  removes the LaunchAgent as part of the migration.
- **Hooks are uninstalled.** Claude's sixteen hooks and status-line wrapper, and
  Cursor's thirteen hooks, are removed from the user's configuration files.
  Backups are written first, and entries AgentHub does not own are preserved.
- **The window is gone.** There is no longer a dashboard, session list, request
  inbox, or handoff surface.

## 8. Testing

- The four quota decoders keep their existing tests, including the fractional
  second reset times that previously froze Claude usage.
- Presentation — naming, ordering, stale and ended states, percentage rounding —
  stays testable without SwiftUI, as it is today.
- Uninstall is tested for preserving foreign entries in both configuration files.
- Hover, pin, and hotkey are verified live on screen; they are not unit tested.
