#!/usr/bin/env bash
# windmill-sync.sh — push/pull the windmill/ folder to the live Windmill
# instance via the wmill CLI (repo is local-only, so no Git-sync feature;
# this folder IS the source of truth, mirrored with sync).
#
#   scripts/windmill-sync.sh push|pull
#
# Auth: reads the agent token from $CONF/windmill/agent-token (600) and
# passes it via env (WM_TOKEN) - the value never lands in a command string
# written by an agent. Per-call --base-url/--workspace flags (verified:
# 'wmill workspace add' profiles were NOT picked up by sync in 1.862.1).
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
CONF="${AI_LAB_CONFIG_DIR:-${HOME}/.config/containers/config}"
BASE="${WM_BASE_URL:-http://127.0.0.1:3117}"
WS="${WM_WORKSPACE_NAME:-kb}"
TOKEN_FILE="$CONF/windmill/agent-token"

cmd="${1:?usage: windmill-sync.sh push|pull}"
[ -f "$TOKEN_FILE" ] || { echo "no agent token - run scripts/windmill-bootstrap.sh first" >&2; exit 1; }
export WM_TOKEN="$(cat "$TOKEN_FILE")"

cd "$ROOT/windmill"
# CLI quirk (1.862.1): --base-url forces --token in argv; WM_TOKEN env alone
# is not picked up by sync. Token read from the 600 file at runtime.
case "$cmd" in
    push) wmill sync push --yes --base-url "$BASE" --workspace "$WS" --token "$WM_TOKEN" ;;
    pull) wmill sync pull --base-url "$BASE" --workspace "$WS" --token "$WM_TOKEN" ;;
    *) echo "usage: windmill-sync.sh push|pull" >&2; exit 1 ;;
esac
