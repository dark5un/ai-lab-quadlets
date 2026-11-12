#!/bin/sh
# run-bridge.sh — start the MaxPresence audio bridge against the live plexpipe
# door. Resolves the ai peer's MagicDNS name from tailscale (strips the
# trailing dot — see doc pitfall) and execs maxaudiod run. Extra args pass
# through (e.g. --gate, -v).
#
# NOTE: this opens the MAX Out capture stream (virtual device input = TCC mic
# access). Owner consent applies (standing policy 2026-11-12).
set -e
cd "$(dirname "$0")"
TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
D=$("$TS" status -json | python3 -c 'import json,sys;print(next((p.get("DNSName") or "") for p in json.load(sys.stdin)["Peer"].values() if p.get("HostName")=="ai").rstrip("."))')
test -n "$D" || { echo "tailscale peer 'ai' not found"; exit 1; }
exec uv run python maxaudiod.py run --door "wss://$D:8457" "$@"
