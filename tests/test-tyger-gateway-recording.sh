#!/usr/bin/env bash
# The gateway's session recorder (V05.4) must write both legs of a session at the right rate and
# length: uplink.wav 16 kHz (what tyger heard), downlink.wav 24 kHz (what tyger said), plus
# session.txt. A wrong rate or a dropped tail would make the owner's replay sound wrong while the
# live call was fine, so this drives the recorder directly inside the running container.
#
# It is a regression guard, not Gate evidence.
#
#   tests/test-tyger-gateway-recording.sh [CONTAINER]    (default: systemd-tyger-gateway)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTR="${1:-systemd-tyger-gateway}"
CHECK="$ROOT/containers/tyger-gateway/scripts/recording-check.py"

if ! podman container exists "$CTR"; then
    echo "recording: no container '$CTR' (start tyger-gateway first)"
    exit 1
fi
# -i matters: without it the container sees an empty stdin and the check silently does nothing.
podman exec -i "$CTR" python3 - <"$CHECK"
code=$?
[ "$code" -eq 0 ] && echo "Session recording passed." || echo "Session recording FAILED (exit $code)."
exit "$code"
