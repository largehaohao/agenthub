#!/bin/zsh
set -euo pipefail

swift test
xcodegen generate
xcodebuild \
  -project AgentHub.xcodeproj \
  -scheme AgentHubApp \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/xcode \
  CODE_SIGNING_ALLOWED=NO \
  build
