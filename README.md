# AgentHub

AgentHub is a macOS menu bar panel that shows how much of your coding-agent
subscriptions you have used.

It reads usage for four providers and shows them in one place:

| Provider | Windows | Source |
|---|---|---|
| Claude | 5h, 7d | Anthropic's usage endpoint, via the OAuth token Claude Code stores in the login Keychain |
| Codex | 5h, 7d | a short-lived `codex app-server` |
| Cursor | billing cycle, split API / Auto / Total | `cursor.com` usage summary, after you authorise it |
| OpenCode | 5h, 7d, 30d | `opencode.ai` Go usage, via the key the CLI stores |

Hover the menu bar icon to see them, click to pin the panel, or press ⌥⌘U from
anywhere. Usage refreshes every fifteen minutes, and the pinned panel has a
refresh button.

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

Two providers need a one-time approval before they report:

- **Claude** reads the OAuth token Claude Code keeps in your login Keychain.
  macOS asks you to allow that the first time, so expect a Keychain dialog;
  choose "Always Allow" if you would rather not see it again. Until then the
  Claude row is simply absent.
- **Cursor** is opt-in. Until you authorise it in Settings, AgentHub does not
  read the session token Cursor stores on this Mac.

## Credentials

Every provider token is read at the moment of the request, kept in memory for
that request, and never written to disk, a log, or the panel. `scripts/check.sh`
enforces this: token literals may appear only in the three reader files that
need them, and never in the app.

AgentHub never installs software or shells out to a package manager to obtain
usage.
