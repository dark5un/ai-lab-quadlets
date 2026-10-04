#!/usr/bin/env bash
# Run every tests/test-*.sh and report pass/fail.
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."
fail=0
for t in tests/test-*.sh; do
    if bash "$t" >/dev/null 2>&1; then
        echo "  PASS  $t"
    else
        echo "  FAIL  $t"
        fail=1
    fi
done
exit $fail
