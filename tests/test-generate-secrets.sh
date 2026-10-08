#!/usr/bin/env bash
# generate-secrets.sh writes into the config dir (never the repo), creates
# dirs 700 / files 600, keeps existing secrets, and gates Hermes behind its flag.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ai-lab-secrets-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export AI_LAB_CONFIG_DIR="$TMP/conf"
fail() { echo "  FAIL: $*"; exit 1; }
before="$(git -C "$ROOT" status --porcelain --ignored config 2>/dev/null || true)"

bash "$ROOT/scripts/generate-secrets.sh" > "$TMP/1.log"
ow="$AI_LAB_CONFIG_DIR/open-webui/service.env"
keys="$AI_LAB_CONFIG_DIR/llama-cpp/keys.txt"
[ "$(stat -c %a "$ow")" = 600 ] || fail "open-webui env not 600"
[ "$(stat -c %a "$keys")" = 600 ] || fail "keys.txt not 600"
[ "$(stat -c %a "$AI_LAB_CONFIG_DIR/llama-cpp")" = 700 ] || fail "llama-cpp dir not 700"
grep -q 'change-me' "$ow" && fail "placeholder left in open-webui env"
grep -Eq '^[0-9a-f]{32}$' "$keys" || fail "keys.txt is not one 32-hex key"
[ ! -e "$AI_LAB_CONFIG_DIR/hermes-service" ] || fail "hermes config written without --with-hermes"

# Re-run keeps the live secrets.
k1="$(cat "$keys")"; s1="$(sha256sum < "$ow")"
bash "$ROOT/scripts/generate-secrets.sh" > /dev/null
[ "$(cat "$keys")" = "$k1" ] && [ "$(sha256sum < "$ow")" = "$s1" ] || fail "re-run changed secrets"

bash "$ROOT/scripts/generate-secrets.sh" --with-hermes > /dev/null
h="$AI_LAB_CONFIG_DIR/hermes-service/service.env"
[ "$(stat -c %a "$h")" = 600 ] || fail "hermes env not 600"
grep -q 'change-me' "$h" && fail "placeholder left in hermes env"

# Nothing written into the repo.
after="$(git -C "$ROOT" status --porcelain --ignored config 2>/dev/null || true)"
[ "$before" = "$after" ] || fail "generate-secrets.sh touched the repo's config/"
echo "Secret generation passed."
