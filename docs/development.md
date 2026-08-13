# Development and operations

Run all commands from the repository root.

## Verify and build

The complete local gate runs the package tests, regenerates the Xcode project,
runs the app test bundle, and checks the source rules:

```bash
zsh scripts/check.sh
```

To build and launch the app on its own:

```bash
xcodegen generate
xcodebuild -project AgentHub.xcodeproj -scheme AgentHubApp \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build
open .build/xcode/Build/Products/Debug/AgentHubApp.app
```

AgentHub is an `LSUIElement`: no Dock icon, no window, just the menu bar item.
`pgrep -f AgentHubApp` is the quickest check that it is running.

## Layout

| Path | What lives there |
|---|---|
| `Sources/AgentHubQuota` | The four provider readers, `QuotaWindow`, and `QuotaService` |
| `Sources/AgentHubQuota/CodexRPC` | JSON-RPC plumbing for the Codex app server |
| `App/MenuBar` | Status item, hover behaviour, the panel and its presentation |
| `App/Settings` | Cursor authorisation, shortcut display |
| `App/Migration` | Removes the daemon and hooks older versions installed |

## Testing usage sources by hand

Each reader can be checked against the provider directly. Claude, for example:

```bash
TOK=$(security find-generic-password -s "Claude Code-credentials" -w \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])")
curl -s -H "Authorization: Bearer $TOK" -H "anthropic-beta: oauth-2025-04-20" \
  https://api.anthropic.com/api/oauth/usage | python3 -m json.tool | head -12
```

The panel should show the same `five_hour` and `seven_day` figures.

Cursor usage only works after authorising it in Settings; until then that
provider reports nothing, which is the intended signed-out state rather than an
error.

## Source rules

`scripts/check.sh` fails the build if either is broken:

- Provider token literals appear only in `ClaudeQuota.swift`,
  `CursorQuota.swift`, and `CursorLoginSessionReader.swift`, and never under
  `App/`. A token is read for one request and never persisted.
- Nothing invokes a package manager or `sudo`. Usage comes from the providers
  themselves.
