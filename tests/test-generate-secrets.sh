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

# Memory group: openviking root key + honcho secrets (one DB password reused
# in POSTGRES_PASSWORD and DB_CONNECTION_URI; JWT distinct).
ov="$AI_LAB_CONFIG_DIR/openviking/service.env"
[ "$(stat -c %a "$ov")" = 600 ] || fail "openviking env not 600"
[ "$(stat -c %a "$AI_LAB_CONFIG_DIR/openviking")" = 700 ] || fail "openviking dir not 700"
grep -q 'change-me' "$ov" && fail "placeholder left in openviking env"
hc="$AI_LAB_CONFIG_DIR/honcho/service.env"
[ "$(stat -c %a "$hc")" = 600 ] || fail "honcho env not 600"
[ "$(stat -c %a "$AI_LAB_CONFIG_DIR/honcho")" = 700 ] || fail "honcho dir not 700"
grep -q 'change-me' "$hc" && fail "placeholder left in honcho env"
hc_pw=$(sed -n 's/^POSTGRES_PASSWORD=//p' "$hc" | tail -1)
hc_uri=$(sed -n 's/^DB_CONNECTION_URI=//p' "$hc" | tail -1)
grep -qF ":${hc_pw}@" <<<"$hc_uri" || fail "honcho DB password not reused in DB_CONNECTION_URI"
hc_jwt=$(sed -n 's/^AUTH_JWT_SECRET=//p' "$hc" | tail -1)
[ -n "$hc_pw" ] && [ -n "$hc_jwt" ] && [ "$hc_pw" != "$hc_jwt" ] || fail "honcho secrets missing or identical"

# Re-run keeps the live memory secrets too.
k1=$(sed -n 's/^OPENVIKING_ROOT_API_KEY=//p' "$ov" | tail -1)
bash "$ROOT/scripts/generate-secrets.sh" > /dev/null
[ "$(sed -n 's/^OPENVIKING_ROOT_API_KEY=//p' "$ov" | tail -1)" = "$k1" ] || fail "openviking key changed on re-run"
[ "$(sed -n 's/^AUTH_JWT_SECRET=//p' "$hc" | tail -1)" = "$hc_jwt" ] || fail "honcho JWT secret changed on re-run"

# Nothing written into the repo.
after="$(git -C "$ROOT" status --porcelain --ignored config 2>/dev/null || true)"
[ "$before" = "$after" ] || fail "generate-secrets.sh touched the repo's config/"
echo "Secret generation passed."
