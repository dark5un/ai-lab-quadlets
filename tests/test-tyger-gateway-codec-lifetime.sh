#!/usr/bin/env bash
# The tyger-gateway must survive a barge without breaking the audio chain. sphn 0.1.12 gives each codec
# object its own Ogg stream; dropping one is harmless, but a live reader dies for good if it is fed a
# page from a SECOND stream (a fresh OpusStreamWriter starts a new stream, and the peer's reader can
# never reach the header again). The gateway used to build a new writer on a barge (OpusEncoder.reset
# replaced the writer) and on every tyger reconnect, so the Ogg stream it sends plexpipe restarted and
# plexpipe's live reader died -- the whole chain stayed dead until a process restart (2026-11-14:
# 358 'plex streaming' lines, one per second, for 6.5 minutes).
#
# This runs the gateway's OWN codec layer through N >= 3 session-shaped lifecycles inside the running
# container, each with a barge. It is a regression guard for the fix, not Gate evidence.
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
