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

# Both helpers ship together: without the hook bridge, Claude sessions started
# outside AgentHub are never observed.
for helper in "$HELPER_PATH" "$CLAUDE_HOOK_PATH"; do
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

# Installing software is only ever an explicit user action, so the Homebrew
# invocation must exist in exactly one reviewable place.
if rg -n -- 'install", "--cask|install --cask' Sources App \
  | rg -v '^Sources/AgentHubClaude/CodexBarInstaller\.swift:' >/dev/null; then
  print -u2 -- "Package installation must only be built in CodexBarInstaller"
  exit 1
fi

# A quota source is never trusted enough to run through a shell.
if rg -n 'sudo|/bin/sh|/bin/bash' Sources/AgentHubClaude >/dev/null; then
  print -u2 -- "Claude quota commands must never use a shell or sudo"
  exit 1
fi
