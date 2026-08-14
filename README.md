# AgentHub

AgentHub is a macOS menu bar panel that shows how much of your coding-agent
subscriptions you have used.

It reads usage for four providers and shows them in one place:

| Provider | Windows | Source |
|---|---|---|
| Claude | 5h, 7d | Anthropic's usage endpoint, via the OAuth token Claude Code stores |
| Codex | 5h, 7d | a short-lived `codex app-server` |
| Cursor | billing cycle, split API / Auto / Total | `cursor.com` usage summary, after you authorise it |
| OpenCode | 5h, 7d, 30d | `opencode.ai` Go usage, via the key the CLI stores |

Hover the menu bar icon to see them, click to pin the panel, or press ⇧⌘T from
anywhere — the shortcut is rebindable in Settings. Usage refreshes every fifteen
minutes, and the pinned panel has a refresh button. The `−` and `+` buttons zoom
the whole panel, from 80% to 250%, and the size is remembered.

A provider that reports nothing says why instead of leaving a gap.

Settings chooses which providers appear. A hidden one is not merely left out of
the panel — it is never contacted, so hiding Codex stops spawning a subprocess
and hiding Cursor stops calling `cursor.com`.

## What it does not do

AgentHub used to manage agent sessions — listing them, approving permission
requests, handing context between agents. That is gone. Only Cursor exposed live
desktop sessions; Claude Desktop cannot be observed at all, and Codex Desktop
threads are not reachable from an app server we can start. The reasoning is in
`docs/superpowers/specs/2026-08-13-agenthub-quota-menubar-design.md`.

## Build

```bash
xcodegen generate
xcodebuild -project AgentHub.xcodeproj -scheme AgentHubApp \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build
open .build/xcode/Build/Products/Debug/AgentHubApp.app
```

`zsh scripts/check.sh` runs the whole gate: package tests, the app test bundle,
and the source rules below.

## Running it

AgentHub has no Dock icon and no window — it lives in the menu bar. Nothing
starts it for you, so **add it to Login Items** if you want it always there.

On first launch it removes what older versions installed: the
`com.agenthub.daemon` LaunchAgent, AgentHub's Claude hooks and status-line
wrapper, and AgentHub's Cursor hooks. Hooks belonging to other tools are left
alone, and both files are backed up first.

**Cursor** is opt-in: until you authorise it in Settings, AgentHub does not read
the session token Cursor stores on this Mac.

**Claude** works as long as Claude Code is signed in. Claude Code keeps its
credential in `~/.claude/.credentials.json` or in the login Keychain, and a Mac
can hold both — one of them a dead leftover from an older sign-in — so AgentHub
reads whichever has the later expiry rather than preferring either.

Claude's access token lasts eight hours and Claude Code only renews it when it
makes a request, so a Mac that has not run it since this morning holds an expired
one. AgentHub then performs the same refresh Claude Code performs and writes the
result back to the same store, so a rotated refresh token does not log the CLI
out. This is the one credential AgentHub writes, and it writes it only where
Claude Code already keeps it. If the refresh token is itself dead, the panel says
so and `claude auth login` is the fix.

## Why AgentHub reads your shell environment

Codex is the only provider AgentHub shells out to. An app launched from Finder
inherits launchd's environment, which is nearly empty — no `PATH` pointing at
per-user CLI installs, and no proxy variables. That broke Codex twice: once
because `codex` could not be found, once because it started but could not reach
the network.

So AgentHub asks your login shell what it exports (`$SHELL -ilc`, once per
launch) and hands that to `codex`, giving it the same environment the command
would have in your terminal. Nothing is stored, and the shell is only ever asked
to print its environment.

`URLSession` reads the system proxy configuration by itself, so the other three
providers never needed this.

## Credentials

Every provider token is read at the moment of the request, kept in memory for
that request, and never written to disk, a log, or the panel. `scripts/check.sh`
enforces this: token literals may appear only in the three reader files that
need them, and never in the app.

AgentHub never installs software or shells out to a package manager to obtain
usage.
