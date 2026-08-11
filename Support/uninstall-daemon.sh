#!/bin/zsh
set -euo pipefail

SUPPORT_DIR="$HOME/Library/Application Support/AgentHub"
DAEMON_PATH="$SUPPORT_DIR/bin/agenthubd"
PLIST_PATH="$HOME/Library/LaunchAgents/com.agenthub.daemon.plist"
DOMAIN="gui/$(id -u)"
TRASH_DIR="$HOME/.Trash"
STAMP=$(/bin/date +%Y%m%d-%H%M%S)
DRY_RUN=0

if [[ ${1:-} == "--dry-run" ]]; then
    DRY_RUN=1
elif [[ $# -gt 0 ]]; then
    print -u2 -- "usage: $0 [--dry-run]"
    exit 64
fi

if (( DRY_RUN )); then
    print -r -- "launchctl bootout $DOMAIN/com.agenthub.daemon"
    print -r -- "move to Trash: $PLIST_PATH"
    print -r -- "move to Trash: $DAEMON_PATH"
    exit 0
fi

/bin/launchctl bootout "$DOMAIN/com.agenthub.daemon" 2>/dev/null || true
/bin/mkdir -p "$TRASH_DIR"
if [[ -e "$PLIST_PATH" ]]; then
    /bin/mv "$PLIST_PATH" "$TRASH_DIR/com.agenthub.daemon.$STAMP.plist"
fi
if [[ -e "$DAEMON_PATH" ]]; then
    /bin/mv "$DAEMON_PATH" "$TRASH_DIR/agenthubd.$STAMP"
fi
print -r -- "AgentHub daemon stopped; installed files were moved to Trash."
