#!/bin/zsh
set -euo pipefail

git diff --check
swift test
xcodegen generate
xcodebuild \
  -project AgentHub.xcodeproj \
  -scheme AgentHubApp \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/xcode \
  CODE_SIGNING_ALLOWED=NO \
  test

# A provider token is read for one request and never persisted by AgentHub.
# Claude's is the one exception: it is renewed in place inside Claude Code's own
# Keychain item, which ClaudeTokenRefresh.swift owns. These are the only files
# permitted to name a token.
token_names='accessToken|refreshToken|WorkosCursorSessionToken'
if rg -n "$token_names" Sources \
  | rg -v '^Sources/AgentHubQuota/ClaudeQuota\.swift:' \
  | rg -v '^Sources/AgentHubQuota/ClaudeTokenRefresh\.swift:' \
  | rg -v '^Sources/AgentHubQuota/CursorLoginSessionReader\.swift:' \
  | rg -v '^Sources/AgentHubQuota/CursorQuota\.swift:' >/dev/null; then
  print -u2 -- "Provider token literals are confined to their readers"
  exit 1
fi
if rg -n "$token_names" App >/dev/null; then
  print -u2 -- "Provider token literals must not appear in the app"
  exit 1
fi

# Usage is read from the providers themselves; AgentHub must never install
# software or shell out to a package manager to obtain it.
if rg -n -- 'brew |--cask|sudo ' Sources App >/dev/null; then
  print -u2 -- "AgentHub must never invoke a package manager or sudo"
  exit 1
fi
