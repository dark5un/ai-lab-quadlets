#!/bin/bash
# Install/remove the maxaudiod LaunchAgent (owner-approved autostart,
# 2026-11-12: replaces manual run-bridge.sh terminals; MAXBar remains the
# per-session kill switch via the runtime control file).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
LBL=com.onlyascii.maxaudiod
AGENT=~/Library/LaunchAgents/$LBL.plist
case "${1:-install}" in
  install)
    cp "$DIR/$LBL.plist" "$AGENT"
    # avoid duplicate bridges: kill any manual instance first
    pkill -f "maxaudiod.py run" 2>/dev/null || true
    sleep 2
    launchctl bootstrap "gui/$(id -u)" "$AGENT" 2>/dev/null || \
      launchctl kickstart -k "gui/$(id -u)/$LBL"
    sleep 6
    launchctl print "gui/$(id -u)/$LBL" | grep -E "state|pid" | head -3
    echo "logs: ~/Library/Application Support/MaxPresence/maxaudiod.log"
    ;;
  remove)
    launchctl bootout "gui/$(id -u)/$LBL" 2>/dev/null || true
    rm -f "$AGENT"
    echo "removed"
    ;;
  status)
    launchctl print "gui/$(id -u)/$LBL" 2>/dev/null | grep -E "state|pid =" | head -3
    pgrep -fl "maxaudiod.py run" || echo "no bridge process"
    ;;
esac
