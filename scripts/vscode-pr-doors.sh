#!/usr/bin/env bash
# vscode-pr-doors.sh — one-time (idempotent) tailnet TLS doors for the
# per-PR VS Code review box pool:
#
#   https://ai.<tailnet>.ts.net:8450..8455  ->  http://127.0.0.1:3130..3135
#
# The boxes publish loopback-only (see scripts/vscode-pr-env.sh); these
# persistent `tailscale serve` listeners make them reachable from the tailnet
# with TLS. Created ONCE, out-of-band; pipelines never touch tailscale.
#
# --bg is mandatory from scripts (tailscale 1.104: without it the command
# blocks in a watcher and never commits — live-verified pattern).
set -euo pipefail

BASE="https://ai.$(tailscale status --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["Self"]["DNSName"].split(".",1)[1])')"
ports=(3130 3131 3132 3133 3134 3135)
n=0
for hp in "${ports[@]}"; do
    ts=$((8450 + n)); n=$((n + 1))
    echo "door :$ts -> 127.0.0.1:$hp"
    tailscale serve --bg --https="$ts" "http://127.0.0.1:$hp"
done
echo; tailscale serve status | grep -E 'https://.*(845[0-5])'
