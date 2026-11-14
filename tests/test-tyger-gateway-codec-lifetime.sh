#!/usr/bin/env bash
# The tyger-gateway must survive many door sessions. sphn 0.1.12 kills every live reader in a process
# the moment any codec object is dropped, OR when a live reader is fed a page from a second Ogg stream
# (a fresh OpusStreamWriter starts a new serial). The gateway used per-session codecs, and its barge
# path (OpusEncoder.reset) replaced its writer, so a barge or a teardown restarted the Ogg stream it
# sends plexpipe -- plexpipe's reader died and the whole chain stayed dead until a process restart
# (2026-11-14: 358 'plex streaming' lines, one per second, for 6.5 minutes).
#
# This runs the gateway's OWN codec layer through N >= 3 session-shaped lifecycles inside the running
# container. It is a regression guard for the fix, not Gate evidence (the Gate is the real chain).
#
#   tests/test-tyger-gateway-codec-lifetime.sh [CONTAINER]    (default: systemd-tyger-gateway)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTR="${1:-systemd-tyger-gateway}"
CHECK="$ROOT/containers/tyger-gateway/scripts/codec-lifetime-check.py"

if ! podman container exists "$CTR"; then
    echo "codec-lifetime: no container '$CTR' (start tyger-gateway first)"
    exit 1
fi
# -i matters: without it the container sees an empty stdin and the check silently does nothing.
podman exec -i "$CTR" python3 - <"$CHECK"
code=$?
[ "$code" -eq 0 ] && echo "Codec lifetime passed." || echo "Codec lifetime FAILED (exit $code)."
exit "$code"
