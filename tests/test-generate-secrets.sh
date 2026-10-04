#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-$HOME/.cache}/ai-lab-secrets-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/scripts" "$TMP/config/open-webui" "$TMP/config/hermes-service" "$TMP/config/llama.cpp"
cp "$ROOT/scripts/generate-secrets.sh" "$TMP/scripts/"
cp "$ROOT/config/open-webui/service.env.example" "$TMP/config/open-webui/"
cp "$ROOT/config/hermes-service/service.env.example" "$TMP/config/hermes-service/"

bash "$TMP/scripts/generate-secrets.sh" > "$TMP/default.log"
[[ ! -e "$TMP/config/hermes-service/service.env" ]]
! grep -q 'Dashboard password:' "$TMP/default.log"
[[ "$(stat -c '%a' "$TMP/config/open-webui/service.env")" == 600 ]]
[[ "$(stat -c '%a' "$TMP/config/llama.cpp/keys.txt")" == 600 ]]

grep -q 'SKIP: containerized Hermes gateway' "$TMP/default.log"
bash "$TMP/scripts/generate-secrets.sh" --with-hermes > "$TMP/hermes.log"
[[ -e "$TMP/config/hermes-service/service.env" ]]
[[ "$(stat -c '%a' "$TMP/config/hermes-service/service.env")" == 600 ]]
! grep -q 'change-me-to-' "$TMP/config/hermes-service/service.env"
! grep -q 'Dashboard password:' "$TMP/hermes.log"

printf '%s\n' 'Secret generation opt-in/permissions passed.'
