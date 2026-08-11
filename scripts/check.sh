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

if otool -l .build/xcode/Build/Products/Debug/AgentHubApp.app/Contents/Helpers/agenthubd \
  | rg -q '/\.build/xcode/'; then
  print -u2 -- "embedded agenthubd must not link to Xcode build products"
  exit 1
fi
