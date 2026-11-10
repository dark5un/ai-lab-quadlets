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

# vscode: connection token env (600, no placeholder, kept on re-run).
vc="$AI_LAB_CONFIG_DIR/vscode/service.env"
[ "$(stat -c %a "$vc")" = 600 ] || fail "vscode env not 600"
[ "$(stat -c %a "$AI_LAB_CONFIG_DIR/vscode")" = 700 ] || fail "vscode dir not 700"
grep -q 'change-me' "$vc" && fail "placeholder left in vscode env"
v1=$(sed -n 's/^VSCODE_CONNECTION_TOKEN=//p' "$vc" | tail -1)
grep -Eq '^[0-9a-f]{32}$' <<<"$v1" || fail "vscode token is not one 32-hex string"
bash "$ROOT/scripts/generate-secrets.sh" > /dev/null
[ "$(sed -n 's/^VSCODE_CONNECTION_TOKEN=//p' "$vc" | tail -1)" = "$v1" ] || fail "vscode token changed on re-run"

# KB group: ragflow shared env (5 distinct secrets, no leftover placeholder)
# + the mysql.env mirror + kb-postgres/lightrag mirror.
rf="$AI_LAB_CONFIG_DIR/ragflow/service.env"
rfm="$AI_LAB_CONFIG_DIR/ragflow/mysql.env"
[ "$(stat -c %a "$rf")" = 600 ] || fail "ragflow env not 600"
[ "$(stat -c %a "$rfm")" = 600 ] || fail "ragflow mysql.env not 600"
grep -q 'change-me' "$rf" && fail "placeholder left in ragflow env"
grep -q 'change-me' "$rfm" && fail "placeholder left in ragflow mysql.env"
mp=$(sed -n 's/^MYSQL_PASSWORD=//p' "$rf" | tail -1)
mr=$(sed -n 's/^MYSQL_ROOT_PASSWORD=//p' "$rfm" | tail -1)
[ -n "$mp" ] && [ "$mp" = "$mr" ] || fail "ragflow mysql.env does not mirror MYSQL_PASSWORD"
[ "$(sed -n 's/^ELASTIC_PASSWORD=//p' "$rf" | tail -1)" != "$mp" ] || fail "ragflow secrets not distinct"
kbpg="$AI_LAB_CONFIG_DIR/kb-postgres/service.env"
lr="$AI_LAB_CONFIG_DIR/lightrag/service.env"
[ "$(stat -c %a "$kbpg")" = 600 ] || fail "kb-postgres env not 600"
[ "$(stat -c %a "$lr")" = 600 ] || fail "lightrag env not 600"
grep -q 'change-me' "$lr" && fail "placeholder left in lightrag env"
lp=$(sed -n 's/^POSTGRES_PASSWORD=//p' "$kbpg" | tail -1)
lxp=$(sed -n 's/^POSTGRES_PASSWORD=//p' "$lr" | tail -1)
[ -n "$lp" ] && [ "$lp" = "$lxp" ] || fail "lightrag does not mirror kb-postgres POSTGRES_PASSWORD"

# automation group: windmill DB + shared env (DATABASE_URL mirrors the DB pw).
wmdb="$AI_LAB_CONFIG_DIR/windmill-postgres/service.env"
wm="$AI_LAB_CONFIG_DIR/windmill/service.env"
[ "$(stat -c %a "$wmdb")" = 600 ] || fail "windmill-postgres env not 600"
[ "$(stat -c %a "$wm")" = 600 ] || fail "windmill env not 600"
grep -q 'change-me' "$wmdb" && fail "placeholder left in windmill-postgres env"
grep -q 'change-me' "$wm" && fail "placeholder left in windmill env"
wp=$(sed -n 's/^POSTGRES_PASSWORD=//p' "$wmdb" | tail -1)
wu=$(sed -n 's|^DATABASE_URL=.*://[^:]*:\([^@]*\)@.*|\1|p' "$wm" | tail -1)
[ -n "$wp" ] && [ "$wp" = "$wu" ] || fail "windmill DATABASE_URL does not mirror windmill-postgres POSTGRES_PASSWORD"
[ "$(sed -n 's/^SUPERADMIN_SECRET=//p' "$wm" | tail -1)" != "$wp" ] || fail "windmill secrets not distinct"

# pipeline group (agentic-pipeline plan): forge/garage/concourse secrets,
# mirrors, tailnet URL fill, and the key trio.
fgdb="$AI_LAB_CONFIG_DIR/forge/postgres.env"
fg="$AI_LAB_CONFIG_DIR/forge/service.env"
[ "$(stat -c %a "$fgdb")" = 600 ] || fail "forge/postgres.env not 600"
[ "$(stat -c %a "$AI_LAB_CONFIG_DIR/forge")" = 700 ] || fail "forge dir not 700"
[ "$(stat -c %a "$fg")" = 600 ] || fail "forge/service.env not 600"
grep -q 'change-me' "$fgdb" && fail "placeholder left in forge/postgres.env"
grep -q 'change-me' "$fg" && fail "placeholder left in forge/service.env"
grep -Eq '<tailnet>|<node-tailnet-fqdn>' "$fg" && fail "tailnet placeholder left in forge env"
[ "$(sed -n 's/^FORGEJO__server__ROOT_URL=//p' "$fg")" = \
  "https://forge.$(tailscale status --json | python3 -c 'import sys,json;print(json.load(sys.stdin)["Self"]["DNSName"].rstrip(".").split(".",1)[1])')" ] \
  || fail "forge ROOT_URL not filled from the live tailnet"
[ "$(sed -n 's/^FORGEJO__security__SECRET_KEY=//p' "$fg")" = \
  "$(sed -n 's/^FORGEJO__security__SECRET_KEY=//p' "$fg" | head -1 | grep -Eo '^[0-9a-f]{64}$')" ] \
  || fail "forge SECRET_KEY is not 64 hex"
fgp=$(sed -n 's/^POSTGRES_PASSWORD=//p' "$fgdb" | tail -1)
fgm=$(sed -n 's/^FORGEJO__database__PASSWD=//p' "$fg" | tail -1)
[ -n "$fgp" ] && [ "$fgp" = "$fgm" ] || fail "forge/service.env does not mirror forge/postgres.env password"

gt="$AI_LAB_CONFIG_DIR/s3/garage.toml"
[ "$(stat -c %a "$gt")" = 600 ] || fail "s3/garage.toml not 600"
grep -q 'change-me' "$gt" && fail "placeholder left in garage.toml"
[ "$(grep -cE '^rpc_secret = "[0-9a-f]{64}"' "$gt")" = 1 ] || fail "garage rpc_secret not a 64-hex value"
[ "$(grep '^admin_token = ' "$gt")" != "$(grep '^metrics_token = ' "$gt")" ] || fail "garage tokens identical"

copg="$AI_LAB_CONFIG_DIR/concourse-postgres/service.env"
cw="$AI_LAB_CONFIG_DIR/concourse/web.env"
cwo="$AI_LAB_CONFIG_DIR/concourse/worker.env"
cm="$AI_LAB_CONFIG_DIR/concourse/mcp.env"
for f in "$copg" "$cw" "$cwo" "$cm"; do
    [ "$(stat -c %a "$f")" = 600 ] || fail "$f not 600"
    grep -q 'change-me' "$f" && fail "placeholder left in $f"
done
grep -q '<tailnet>' "$cw" && fail "tailnet placeholder left in concourse web.env"
[ "$(sed -n 's/^CONCOURSE_POSTGRES_PASSWORD=//p' "$cw")" = \
  "$(sed -n 's/^POSTGRES_PASSWORD=//p' "$copg" | tail -1)" ] \
  || fail "concourse web.env does not mirror concourse-postgres password"
ckeys="$AI_LAB_CONFIG_DIR/concourse/keys"
[ "$(stat -c %a "$ckeys")" = 700 ] || fail "concourse keys dir not 700"
for kf in tsa_host_key tsa_host_key.pub session_signing_key worker_key worker_key.pub authorized_worker_keys; do
    [ -f "$ckeys/$kf" ] || fail "concourse key missing: $kf"
    [ "$(stat -c %a "$ckeys/$kf")" = 600 ] || fail "concourse key not 600: $kf"
done
diff -q "$ckeys/worker_key.pub" "$ckeys/authorized_worker_keys" || fail "authorized_worker_keys != worker_key.pub"
cppw=$(sed -n 's/^CONCOURSE_ADD_LOCAL_USER=pipeline:\([^,]*\),.*/\1/p' "$cw" | tail -1)
capw=$(sed -n 's/^CONCOURSE_ADD_LOCAL_USER=[^,]*,agent:\(.*\)$/\1/p' "$cw" | tail -1)
[ -n "$cppw" ] && [ -n "$capw" ] && [ "$cppw" != "$capw" ] || fail "concourse local users missing/identical"
[ "$(sed -n 's/^CONCOURSE_PASSWORD=//p' "$cm")" = "$cppw" ] || fail "mcp.env does not mirror pipeline password"
[ "$(sed -n 's/^CONCOURSE_LOWPRIV_PASSWORD=//p' "$cm")" = "$capw" ] || fail "mcp.env does not mirror agent password"
[ "$(sed -n 's/^MCP_TOKEN_HERMES=//p' "$cm")" != "$(sed -n 's/^MCP_TOKEN_PIPELINE=//p' "$cm")" ] || fail "mcp tokens identical"

# notebook server: token file + env (600, kept on re-run).
ntk="$AI_LAB_CONFIG_DIR/notebook/jupyter-token"
ne="$AI_LAB_CONFIG_DIR/notebook/service.env"
[ "$(stat -c %a "$ntk")" = 600 ] || fail "notebook jupyter-token not 600"
[ -s "$ntk" ] || fail "notebook jupyter-token empty"
[ "$(stat -c %a "$ne")" = 600 ] || fail "notebook env not 600"
tk_h="$(sha256sum < "$ntk")"

# ailab-api control bearer (mode 600, generated 64-hex token, kept on re-run).
ae="$AI_LAB_CONFIG_DIR/ailab-api/service.env"
[ "$(stat -c %a "$ae")" = 600 ] || fail "ailab-api env not 600"
grep -q 'change-me' "$ae" && fail "placeholder left in ailab-api env"
grep -Eq '^AILAB_API_TOKEN=[0-9a-f]{64}$' "$ae" || fail "ailab-api token is not one 64-hex value"
ae_h="$(sha256sum < "$ae")"

# Re-run keeps the live KB secrets too.
rf_h="$(sha256sum < "$rf")"; kb_h="$(sha256sum < "$kbpg")"
wm_h="$(sha256sum < "$wm")"; wmdb_h="$(sha256sum < "$wmdb")"
fg_h="$(sha256sum < "$fg")"; gt_h="$(sha256sum < "$gt")"
cw_h="$(sha256sum < "$cw")"; cm_h="$(sha256sum < "$cm")"
bash "$ROOT/scripts/generate-secrets.sh" > /dev/null
[ "$(sha256sum < "$rf")" = "$rf_h" ] || fail "ragflow env changed on re-run"
[ "$(sha256sum < "$kbpg")" = "$kb_h" ] || fail "kb-postgres env changed on re-run"
[ "$(sha256sum < "$wm")" = "$wm_h" ] || fail "windmill env changed on re-run"
[ "$(sha256sum < "$wmdb")" = "$wmdb_h" ] || fail "windmill-postgres env changed on re-run"
[ "$(sha256sum < "$ntk")" = "$tk_h" ] || fail "notebook jupyter-token changed on re-run"
[ "$(sha256sum < "$ae")" = "$ae_h" ] || fail "ailab-api env changed on re-run"
[ "$(sha256sum < "$fg")" = "$fg_h" ] || fail "forge env changed on re-run"
[ "$(sha256sum < "$gt")" = "$gt_h" ] || fail "garage.toml changed on re-run"
[ "$(sha256sum < "$cw")" = "$cw_h" ] || fail "concourse web.env changed on re-run"
[ "$(sha256sum < "$cm")" = "$cm_h" ] || fail "concourse mcp.env changed on re-run"
[ "$(sed -n 's/^CONCOURSE_PASSWORD=//p' "$cm")" = "$(sed -n 's/^CONCOURSE_ADD_LOCAL_USER=pipeline:\([^,]*\),.*/\1/p' "$cw")" ] \
  || fail "concourse local user password changed on re-run (keys/users must be stable)"

# Nothing written into the repo.
after="$(git -C "$ROOT" status --porcelain --ignored config 2>/dev/null || true)"
[ "$before" = "$after" ] || fail "generate-secrets.sh touched the repo's config/"
echo "Secret generation passed."
