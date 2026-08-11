#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
SUPPORT_DIR="$HOME/Library/Application Support/AgentHub"
BIN_DIR="$SUPPORT_DIR/bin"
LOG_DIR="$SUPPORT_DIR/Logs"
DAEMON_DEST="$BIN_DIR/agenthubd"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$PLIST_DIR/com.agenthub.daemon.plist"
DAEMON_SOURCE=${AGENTHUB_DAEMON_SOURCE:-"$PROJECT_DIR/.build/debug/agenthubd"}
DOMAIN="gui/$(id -u)"
DRY_RUN=0

if [[ ${1:-} == "--dry-run" ]]; then
    DRY_RUN=1
elif [[ $# -gt 0 ]]; then
    print -u2 -- "usage: $0 [--dry-run]"
    exit 64
fi

if (( DRY_RUN )); then
    print -r -- "source: $DAEMON_SOURCE"
    print -r -- "install executable (0700): $DAEMON_DEST"
    print -r -- "install plist (0600): $PLIST_PATH"
    print -r -- "launchctl bootout $DOMAIN/com.agenthub.daemon"
    print -r -- "launchctl bootstrap $DOMAIN $PLIST_PATH"
    print -r -- "launchctl kickstart -k $DOMAIN/com.agenthub.daemon"
    exit 0
fi

if [[ ! -x "$DAEMON_SOURCE" ]]; then
    print -u2 -- "agenthubd executable not found: $DAEMON_SOURCE"
    exit 66
fi

umask 077
/bin/mkdir -p "$BIN_DIR" "$LOG_DIR" "$PLIST_DIR"
/bin/chmod 700 "$SUPPORT_DIR" "$BIN_DIR" "$LOG_DIR"
/usr/bin/install -m 700 "$DAEMON_SOURCE" "$DAEMON_DEST"

TEMP_PLIST=$(/usr/bin/mktemp "$SUPPORT_DIR/.com.agenthub.daemon.XXXXXX")
trap '/bin/rm -f "$TEMP_PLIST"' EXIT
/bin/cp "$SCRIPT_DIR/com.agenthub.daemon.plist" "$TEMP_PLIST"
/usr/bin/plutil -insert ProgramArguments.0 -string "$DAEMON_DEST" "$TEMP_PLIST"
/usr/bin/plutil -replace EnvironmentVariables.PATH -string "${PATH:-/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}" "$TEMP_PLIST"
/usr/bin/plutil -replace StandardOutPath -string "$LOG_DIR/agenthubd.log" "$TEMP_PLIST"
/usr/bin/plutil -replace StandardErrorPath -string "$LOG_DIR/agenthubd.error.log" "$TEMP_PLIST"
/usr/bin/plutil -replace WorkingDirectory -string "$SUPPORT_DIR" "$TEMP_PLIST"
/usr/bin/install -m 600 "$TEMP_PLIST" "$PLIST_PATH"

/bin/launchctl bootout "$DOMAIN/com.agenthub.daemon" 2>/dev/null || true
BOOTSTRAPPED=0
for ATTEMPT in {1..10}; do
    if /bin/launchctl bootstrap "$DOMAIN" "$PLIST_PATH" 2>/dev/null; then
        BOOTSTRAPPED=1
        break
    fi
    /bin/sleep 0.5
done
if (( ! BOOTSTRAPPED )); then
    print -u2 -- "unable to bootstrap AgentHub daemon"
    exit 70
fi
/bin/launchctl kickstart -k "$DOMAIN/com.agenthub.daemon"
print -r -- "AgentHub daemon installed for the current user."
