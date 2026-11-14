#!/usr/bin/env bash
# The tyger-gateway must put EVERY frame of a reply on the wire, not 160 ms less. sphn 0.1.12's
# OpusStreamWriter emits its Ogg OpusHead/OpusTags pages on its first read_bytes() calls, and the
# gateway counted each read as one 80 ms frame, so the first two reads were spent on headers and the
# last two audio frames were never read out -- every reply reached the door exactly 160 ms short
# (2026-11-14: 152 frames in -> 150 out; the Mac played 288000 of 291840 samples, and the honest
# report stayed below tyger's sent count so the turn ended on the 2 s fallback).
#
# This drives the gateway's OWN codec layer inside the running container and asserts the peer decodes
# every sample. It is a regression guard for the fix, not Gate evidence.
#
#   tests/test-tyger-gateway-frame-integrity.sh [CONTAINER]    (default: systemd-tyger-gateway)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTR="${1:-systemd-tyger-gateway}"
CHECK="$ROOT/containers/tyger-gateway/scripts/frame-integrity-check.py"

if ! podman container exists "$CTR"; then
    echo "frame-integrity: no container '$CTR' (start tyger-gateway first)"
    exit 1
fi
# -i matters: without it the container sees an empty stdin and the check silently does nothing.
podman exec -i "$CTR" python3 - <"$CHECK"
code=$?
[ "$code" -eq 0 ] && echo "Frame integrity passed." || echo "Frame integrity FAILED (exit $code)."
exit "$code"
