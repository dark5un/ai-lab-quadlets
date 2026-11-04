#!/usr/bin/env bash
# kb-bootstrap.sh - one-time RAGFlow configuration for the KB group
# (knowledge-base plan sec.3/7). Idempotent: safe to re-run.
#
#   ./scripts/kb-bootstrap.sh
#
# Does (all verified live against infiniflow/ragflow v1.0.0-rc3, 2026-11-04):
#   1. waits for ragflow healthz
#   2. registers the kb-bot console user (self-registration is open on a
#      fresh box; login via /api/v1/auth/login returns a ragflow_auth cookie
#      whose VALUE is used as the Bearer token for session endpoints - the
#      super admin account is Admin-service-only and cannot console-login)
#   3. creates an API token (PAT) via POST /api/v1/system/tokens and writes
#      it into config/kb-watcher/service.env (RAGFLOW_API_KEY)
#   4. registers the OpenAI-API-Compatible provider + strata/embeddings
#      instances with the EXACT model ids and sets tenant defaults
#      (model_type is a LIST; the OpenAI-compatible completion endpoint
#      requires "model": "<name>@<instance>@<provider>" in the request)
#   5. creates the three datasets (parse_type=1, parser_id=general)
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONF="${AI_LAB_CONFIG_DIR:-${HOME}/.config/containers/config}"
B="http://127.0.0.1:3114"
SK_KEY="$(sed -n 's/^API_KEY=//p' "$CONF/strata/service.env" | head -1)"
EMB_KEY="$(head -1 "$CONF/llama-cpp/keys.txt" | tr -d ' \n')"
LLM_ID="qwen3.8-flash-next-iq3_s"
EMB_ID="bge-m3"

[ -n "$SK_KEY" ] || { echo "kb-bootstrap: strata API_KEY missing" >&2; exit 1; }
for s in embeddings; do
    systemctl --user is-active --quiet "$s.service" || systemctl --user start "$s.service"
done

echo "1. waiting for ragflow healthz"
for i in $(seq 1 60); do
    h=$(curl -s "$B/api/v1/system/healthz" || true)
    [[ "$h" == *'"status":"ok"'* ]] && break
    sleep 5
done
[[ "$h" == *'"status":"ok"'* ]] || { echo "kb-bootstrap: ragflow not healthy" >&2; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

echo "2. console user kb-bot"
BOT_PW_FILE="$CONF/ragflow/.kbuser_pw_once"
if [ ! -f "$BOT_PW_FILE" ]; then
    openssl rand -hex 16 > "$BOT_PW_FILE"; chmod 600 "$BOT_PW_FILE"
fi
BOT_PW="$(cat "$BOT_PW_FILE")"
login() {
    cat > "$T/login.json" <<EOF
{"email":"kb-bot@local.ai","password":"$BOT_PW"}
EOF
    curl -s -D "$T/hdr" -X POST "$B/api/v1/auth/login" -H 'Content-Type: application/json' -d @"$T/login.json"
}
R=$(login)
if [[ "$R" == *'"code":0'* ]]; then
    :
else
    cat > "$T/reg.json" <<'EOF'
{"nickname":"kb-bot","email":"kb-bot@local.ai","password":"PLACEHOLDER","language":"English"}
EOF
    sed -i "s/PLACEHOLDER/$BOT_PW/" "$T/reg.json"
    curl -s -X POST "$B/api/v1/users" -H 'Content-Type: application/json' -d @"$T/reg.json" >/dev/null
    R=$(login)
fi
[[ "$R" == *'"code":0'* ]] || { echo "kb-bootstrap: cannot log in kb-bot (was the password changed in the UI? delete $BOT_PW_FILE and recreate)" >&2; exit 1; }
SESSION=$(sed -nE 's/.*ragflow_auth=([^;]+).*/\1/p' "$T/hdr" | head -1)

echo "3. API token (PAT) -> config/kb-watcher/service.env"
PAT_JSON=$(curl -s -X POST "$B/api/v1/system/tokens" -H "Authorization: Bearer $SESSION" -H 'Content-Type: application/json' -d '{}')
PAT=$(sed -n 's/.*"token":"\([^"]*\)".*/\1/p' <<<"$PAT_JSON")
[ -n "$PAT" ] || { echo "kb-bootstrap: token creation failed: $PAT_JSON" >&2; exit 1; }
if [ -f "$CONF/kb-watcher/service.env" ]; then
    sed -i "s|^RAGFLOW_API_KEY=.*|RAGFLOW_API_KEY=$PAT|" "$CONF/kb-watcher/service.env"
    chmod 600 "$CONF/kb-watcher/service.env"
    echo "  PAT written (not printed)"
fi

echo "4. provider + instances + defaults"
curl -s -X PUT "$B/api/v1/providers" -H "Authorization: Bearer $PAT" -H 'Content-Type: application/json' \
    -d '{"provider_name":"OpenAI-API-Compatible"}' >/dev/null
cat > "$T/strata.json" <<EOF
{"instance_name":"strata","base_url":"http://systemd-strata:8080/v1","api_key":"$SK_KEY",
 "model_info":[{"model_name":"$LLM_ID","model_type":["chat"],"max_tokens":1048576}]}
EOF
cat > "$T/emb.json" <<EOF
{"instance_name":"embeddings","base_url":"http://systemd-embeddings:8080/v1","api_key":"$EMB_KEY",
 "model_info":[{"model_name":"$EMB_ID","model_type":["embedding"],"max_tokens":8192}]}
EOF
for spec in strata emb; do
    out=$(curl -s -X POST "$B/api/v1/providers/OpenAI-API-Compatible/instances" \
        -H "Authorization: Bearer $PAT" -H 'Content-Type: application/json' -d @"$T/$spec.json")
    [[ "$out" == *'"code":0'* || "$out" == *"already exists"* ]] && echo "  instance $spec ok" || { echo "  ! $out" >&2; exit 1; }
done
for t in chat embedding; do
    if [ "$t" = chat ]; then body="{\"model_type\":\"chat\",\"model_provider\":\"OpenAI-API-Compatible\",\"model_instance\":\"strata\",\"model_name\":\"$LLM_ID\"}";
    else body="{\"model_type\":\"embedding\",\"model_provider\":\"OpenAI-API-Compatible\",\"model_instance\":\"embeddings\",\"model_name\":\"$EMB_ID\"}"; fi
    curl -s -X PATCH "$B/api/v1/models/default" -H "Authorization: Bearer $PAT" -H 'Content-Type: application/json' -d "$body" >/dev/null
done
curl -s "$B/api/v1/models/default" -H "Authorization: Bearer $PAT" | grep -c "$LLM_ID" >/dev/null && echo "  defaults verified"

echo "5. datasets"
for name in docs-general docs-code docs-notes; do
    curl -s -X POST "$B/api/v1/datasets" -H "Authorization: Bearer $PAT" -H 'Content-Type: application/json' \
        -d "{\"name\":\"$name\",\"parse_type\":1,\"parser_id\":\"general\",\"language\":\"English\"}" >/dev/null
done
curl -s "$B/api/v1/datasets" -H "Authorization: Bearer $PAT" | grep -o '"name":"docs-[a-z]*"' | sort -u
echo "kb-bootstrap done. NEXT: seed fixtures into the datasets and start kb-watcher."
