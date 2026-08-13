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

# A provider token is read for one request and never persisted. These are the
# only files permitted to name one.
if rg -n 'accessToken|WorkosCursorSessionToken' Sources \
  | rg -v '^Sources/AgentHubQuota/ClaudeQuota\.swift:' \
  | rg -v '^Sources/AgentHubQuota/CursorLoginSessionReader\.swift:' \
  | rg -v '^Sources/AgentHubQuota/CursorQuota\.swift:' >/dev/null; then
  print -u2 -- "Provider token literals are confined to their readers"
  exit 1
fi
if rg -n 'accessToken|WorkosCursorSessionToken' App >/dev/null; then
  print -u2 -- "Provider token literals must not appear in the app"
  exit 1
fi

# Usage is read from the providers themselves; AgentHub must never install
# software or shell out to a package manager to obtain it.
if rg -n -- 'brew |--cask|sudo ' Sources App >/dev/null; then
  print -u2 -- "AgentHub must never invoke a package manager or sudo"
  exit 1
fi
