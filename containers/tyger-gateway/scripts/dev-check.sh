#!/usr/bin/env bash
# dev-check.sh -- is the gateway up AND is there a real tyger behind it? Exit code is the answer.
#
#   scripts/dev-check.sh [CONTAINER]        (default: systemd-tyger-gateway)
#
# Runs on the ai box, against the running container. No mocks: /health is the gateway's own
# probe of tyger's /voices, so a 200 here means a real EARS is answering through this process.
# Deliberately NOT run through a pipe: a status code read through `tail` hides failures
# (process-failure-analysis.md §3.5).
set -uo pipefail

CTR="${1:-systemd-tyger-gateway}"
PORT="${GATEWAY_PORT:-8994}"
fail=0

if ! podman container exists "$CTR"; then
    echo "dev-check: no container '$CTR' (podman container exists)"
    exit 1
fi
if [ "$(podman inspect "$CTR" --format '{{.State.Running}}')" != "true" ]; then
    echo "dev-check: '$CTR' exists but is not running"
    exit 1
fi

body="$(curl -sS -m 5 "http://127.0.0.1:${PORT}/health")"
code=$?
if [ $code -ne 0 ]; then
    echo "dev-check: /health on 127.0.0.1:${PORT} did not answer (curl exit ${code})"
    exit 1
fi
echo "health: ${body}"
case "$body" in
    *'"ok": true'*) ;;
    *) echo "dev-check: /health says tyger is NOT reachable behind this gateway"; fail=1 ;;
esac

echo "--- last log lines ---"
podman logs --tail 20 "$CTR" 2>&1

exit $fail