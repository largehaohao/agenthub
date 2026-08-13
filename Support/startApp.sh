#!/bin/sh
# Start the locally built AgentHub app.
set -eu

PROJECT_DIR=$(cd "$(dirname "$0")/.." && pwd)
APP="$PROJECT_DIR/.build/xcode/Build/Products/Debug/AgentHubApp.app"

if [ ! -d "$APP" ]; then
    echo "AgentHubApp.app not built: $APP" >&2
    echo "build it with:" >&2
    echo "  xcodegen generate" >&2
    echo "  xcodebuild -project AgentHub.xcodeproj -scheme AgentHubApp \\" >&2
    echo "    -configuration Debug -destination 'platform=macOS' \\" >&2
    echo "    -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build" >&2
    exit 66
fi

if ! pgrep -q -f agenthubd; then
    echo "warning: agenthubd is not running; the app will show no data." >&2
    echo "         install it with: zsh Support/install-daemon.sh" >&2
fi

# Replace any running instance, including a stale copy in ~/Applications, so
# this always launches the build that was just made.
pkill -f AgentHubApp 2>/dev/null || true
sleep 1

open "$APP"
