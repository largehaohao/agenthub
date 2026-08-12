#!/bin/zsh
set -euo pipefail

git diff --check
swift test
plutil -lint Support/com.agenthub.daemon.plist
zsh -n Support/install-daemon.sh Support/uninstall-daemon.sh
xcodegen generate
xcodebuild \
  -project AgentHub.xcodeproj \
  -scheme AgentHubApp \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/xcode \
  CODE_SIGNING_ALLOWED=NO \
  test

HELPERS_DIR=.build/xcode/Build/Products/Debug/AgentHubApp.app/Contents/Helpers
HELPER_PATH="$HELPERS_DIR/agenthubd"
CLAUDE_HOOK_PATH="$HELPERS_DIR/agenthub-claude-hook"
CLAUDE_STATUSLINE_PATH="$HELPERS_DIR/agenthub-claude-statusline"
CURSOR_HOOK_PATH="$HELPERS_DIR/agenthub-cursor-hook"

# All helpers ship together: without the hook bridges, provider sessions started
# outside AgentHub are never observed, and without the status-line reporter no
# Claude usage can be collected.
for helper in "$HELPER_PATH" "$CLAUDE_HOOK_PATH" "$CLAUDE_STATUSLINE_PATH" "$CURSOR_HOOK_PATH"; do
  if [[ ! -x "$helper" ]]; then
    print -u2 -- "missing embedded helper: $helper"
    exit 1
  fi
done

if otool -l "$HELPER_PATH" \
  | rg -q '/\.build/xcode/'; then
  print -u2 -- "embedded agenthubd must not link to Xcode build products"
  exit 1
fi

for module in AgentHubOpenCode AgentHubSecurity AgentHubClaude; do
  if ! strings "$HELPER_PATH" | rg "$module" >/dev/null; then
    print -u2 -- "embedded agenthubd is missing statically linked $module"
    exit 1
  fi
done

# A launch prompt passed as a Claude process argument would be readable by any
# local process. It must only ever travel through a tmux paste buffer.
if rg -n -- '--session-id' Sources App \
  | rg -v '^Sources/AgentHubClaude/ClaudeTerminalRuntime\.swift:' >/dev/null; then
  print -u2 -- "Claude launch arguments must be built only in ClaudeTerminalRuntime"
  exit 1
fi

if rg -n 'pasteLiteral|prompt' Sources/AgentHubClaude/ClaudeTerminalRuntime.swift \
  | rg -q 'arguments:.*prompt'; then
  print -u2 -- "Claude prompt text must never be passed as a process argument"
  exit 1
fi

# Permission prompts are always answered by the user, never by policy.
if rg -n -- '--dangerously-skip-permissions|bypassPermissions' Sources App >/dev/null; then
  print -u2 -- "Claude permission bypass flags are not allowed"
  exit 1
fi

# Usage is collected from Claude itself; AgentHub must never install software
# or shell out to a package manager to obtain it.
if rg -n -- 'brew |--cask|sudo ' Sources App >/dev/null; then
  print -u2 -- "AgentHub must never invoke a package manager or sudo"
  exit 1
fi

# The status line belongs to the user. Only the installer may write that key,
# so a stray writer cannot silently replace their own status line.
if rg -n '"statusLine"' Sources App \
  | rg -v '^Sources/AgentHubClaude/ClaudeStatusLineInstaller\.swift:' >/dev/null; then
  print -u2 -- "Only ClaudeStatusLineInstaller may write the statusLine key"
  exit 1
fi

# Cursor hooks.json belongs to the user. Only the installer may write that file,
# so a stray writer cannot silently replace their own hooks.
if rg -n '\.cursor/hooks\.json|root\["hooks"\]' Sources/AgentHubCursor App Sources/agenthubd \
  | rg -v '^Sources/AgentHubCursor/CursorHookInstaller\.swift:' \
  | rg -v '^Sources/agenthubd/main\.swift:' \
  | rg -v 'App/Features/Cursor/CursorSettingsView\.swift:' >/dev/null; then
  print -u2 -- "Only CursorHookInstaller may mutate ~/.cursor/hooks.json"
  exit 1
fi

# Cursor access tokens stay in process memory only.
if rg -n 'accessToken|WorkosCursorSessionToken' Sources \
  | rg -v '^Sources/AgentHubCursor/CursorLoginSessionReader\.swift:' \
  | rg -v '^Sources/AgentHubCursor/CursorQuotaClient\.swift:' >/dev/null; then
  print -u2 -- "Cursor token literals are confined to the login reader and quota client"
  exit 1
fi
if rg -n 'accessToken|WorkosCursorSessionToken' App >/dev/null; then
  print -u2 -- "Cursor token literals must not appear in App persistence paths"
  exit 1
fi
