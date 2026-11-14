#!/usr/bin/env bash
# The gateway must pair the Mac's playhead tags with the mic blocks they describe. The tag is measured
# at MAX Mic's DAC (V03 step 4, I-26) and travels beside the audio through plexpipe, which resamples
# 48 -> 24 kHz and reframes to 80 ms Opus -- so arrival order cannot pair a tag with its block; the
# capture position inside the tag is what does (containers/tyger-gateway/server.py `tag_for`).
#
# This drives the gateway's own pairing code inside the running container with a synthetic Mac (a
# continuous capture counter, a continuous 20 ms block stream, a reply counting up at 24 kHz). It is a
# regression guard for the arithmetic, not Gate evidence.
#
#   tests/test-tyger-gateway-tag-pairing.sh [CONTAINER]    (default: systemd-tyger-gateway)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTR="${1:-systemd-tyger-gateway}"
CHECK="$ROOT/containers/tyger-gateway/scripts/tag-pairing-check.py"

if ! podman container exists "$CTR"; then
    echo "tag-pairing: no container '$CTR' (start tyger-gateway first)"
    exit 1
fi
# -i matters: without it the container sees an empty stdin and the check silently does nothing.
podman exec -i "$CTR" python3 - <"$CHECK"
code=$?
[ "$code" -eq 0 ] && echo "Tag pairing passed." || echo "Tag pairing FAILED (exit $code)."
exit "$code"