#!/usr/bin/env bash
# rotate-secrets.sh — regenerate leaked/unknown secrets and restart what uses them.
#
#   ./scripts/rotate-secrets.sh [--yes]
#
# Rotates:
#   - open-webui WEBUI_SECRET_KEY   (config/open-webui/service.env)
#   - llama.cpp API keys            (config/llama-cpp/keys.txt, all 3 servers)
#   - strata API_KEY                (config/strata/service.env + every
#                                    ~/.local/share/strata/config-*/strata-*.json)
#   - KB group                      (ragflow service.env + mysql.env mirror,
#                                    kb-postgres + lightrag mirror)
#   - automation group              (windmill-postgres + windmill DATABASE_URL
#                                    mirror, SUPERADMIN_SECRET)
#   - ailab-api AILAB_API_TOKEN      (config/ailab-api/service.env; the Mac
#                                    widget must re-pick up the new token)
#   - pipeline group                (agentic-pipeline plan): forge/postgres.env
#                                    + forge/service.env mirrors, garage.toml
#                                    secrets, concourse-postgres + web.env
#                                    local-user passwords (upserted into the
#                                    ATC DB on web restart) + mcp.env mirrors.
#                                    Garage ACCESS KEYS (bucket creds) are
#                                    minted in Garage's metadata: rotate with
#                                    `podman exec systemd-s3 /garage key create`
#                                    + rewrite config/concourse/pipeline-vars.yml.
# Then restarts the affected services. Existing sessions/cookies tied to the
# old values are invalidated. Treat any leaked value as burned: rotate first,
# then hunt for where it leaked.
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
CONF="${HOME}/.config/containers/config"
APPLY=0
for arg in "$@"; do
    case "$arg" in
        --yes) APPLY=1 ;;
        *) printf 'Unknown option: %s (supported: --yes)\n' "$arg" >&2; exit 2 ;;
    esac
done

rand() { openssl rand -hex "$1"; }

rotate_env_key() { # file KEY
    local file="$1" key="$2"
    [ -f "$file" ] || { echo "  - skip $file (not present)"; return; }
    local new; new=$(rand 32)
    if [ "$APPLY" = 1 ]; then
        local tmp; tmp=$(mktemp "${file}.XXXXXX")
        sed "s|^${key}=.*|${key}=${new}|" "$file" > "$tmp"
        chmod 600 "$tmp"; mv "$tmp" "$file"
        echo "  ✓ rotated ${key} in $file"
    else
        echo "  ~ would rotate ${key} in $file"
    fi
}

echo "Rotating secrets (dry run; pass --yes to apply)..."
[ "$APPLY" = 1 ] && echo "APPLYING."

rotate_env_key "$CONF/open-webui/service.env" WEBUI_SECRET_KEY
rotate_env_key "$CONF/strata/service.env" API_KEY
# KB group: one shared file + two mirrors. The mysql.env / lightrag mirrors
# MUST be rewritten after their source keys (same trick as strata's json
# copies below): ragflow mysql.env takes MYSQL_PASSWORD, lightrag env takes
# kb-postgres POSTGRES_PASSWORD.
rotate_env_key "$CONF/ragflow/service.env" ELASTIC_PASSWORD
rotate_env_key "$CONF/ragflow/service.env" MYSQL_PASSWORD
rotate_env_key "$CONF/ragflow/service.env" MINIO_PASSWORD
rotate_env_key "$CONF/ragflow/service.env" REDIS_PASSWORD
rotate_env_key "$CONF/ragflow/service.env" ADMIN_DEFAULT_PASSWORD
rotate_env_key "$CONF/kb-postgres/service.env" POSTGRES_PASSWORD
rotate_env_key "$CONF/windmill-postgres/service.env" POSTGRES_PASSWORD
rotate_env_key "$CONF/windmill/service.env" SUPERADMIN_SECRET
rotate_env_key "$CONF/ailab-api/service.env" AILAB_API_TOKEN

# Pipeline group (agentic-pipeline plan). Sources first, mirrors after.
rotate_env_key "$CONF/forge/postgres.env" POSTGRES_PASSWORD
rotate_env_key "$CONF/forge/service.env" FORGEJO__security__SECRET_KEY
rotate_env_key "$CONF/forge/service.env" FORGEJO_ADMIN_PASSWORD
rotate_env_key "$CONF/concourse-postgres/service.env" POSTGRES_PASSWORD
rotate_env_key "$CONF/concourse/mcp.env" MCP_TOKEN_HERMES
rotate_env_key "$CONF/concourse/mcp.env" MCP_TOKEN_PIPELINE
# web.env carries both local-user passwords inside one line: rewrite in place.
if [ -f "$CONF/concourse/web.env" ]; then
    if [ "$APPLY" = 1 ]; then
        awk '/^CONCOURSE_ADD_LOCAL_USER=/{
            gsub(/pipeline:[^,]*/, "pipeline:" rand()); gsub(/agent:[^ ]*/, "agent:" rand())
        } 1' RNGSEED="$(openssl rand -hex 8)" "$CONF/concourse/web.env" \
          > "$CONF/concourse/web.env.tmp" && \
        chmod 600 "$CONF/concourse/web.env.tmp" && \
        mv "$CONF/concourse/web.env.tmp" "$CONF/concourse/web.env" && \
        echo "  ✓ rotated concourse local users (pipeline/agent) in web.env"
    else
        echo "  ~ would rotate concourse local users in web.env"
    fi
fi
# garage.toml secrets (quoted-key TOML lines, not KEY=VALUE).
for k in rpc_secret admin_token metrics_token; do
    f="$CONF/s3/garage.toml"
    if [ -f "$f" ]; then
        if [ "$APPLY" = 1 ]; then
            sed "s|^${k} = .*|${k} = \"$(openssl rand -hex 32)\"|" "$f" > "$f.tmp" && \
            chmod 600 "$f.tmp" && mv "$f.tmp" "$f" && echo "  ✓ rotated $k in $f"
        else
            echo "  ~ would rotate $k in $f"
        fi
    fi
done
if [ "$APPLY" = 1 ]; then
    # forge/service.env PASSWD mirrors forge/postgres.env
    fpw=$(sed -n 's/^POSTGRES_PASSWORD=//p' "$CONF/forge/postgres.env" 2>/dev/null | tail -1)
    [ -n "$fpw" ] && [ -f "$CONF/forge/service.env" ] && \
        awk -v p="$fpw" '/^FORGEJO__database__PASSWD=/{print "FORGEJO__database__PASSWD=" p; next} 1' \
            "$CONF/forge/service.env" > "$CONF/forge/service.env.tmp" && \
        chmod 600 "$CONF/forge/service.env.tmp" && mv "$CONF/forge/service.env.tmp" "$CONF/forge/service.env" && \
        echo "  ✓ re-mirrored forge PASSWD"
    # web.env POSTGRES_PASSWORD mirrors concourse-postgres; the pipeline/agent
    # passwords in web.env mirror into mcp.env (CONCOURSE_*/LOWPRIV_*).
    cpw=$(sed -n 's/^POSTGRES_PASSWORD=//p' "$CONF/concourse-postgres/service.env" 2>/dev/null | tail -1)
    [ -n "$cpw" ] && [ -f "$CONF/concourse/web.env" ] && \
        awk -v p="$cpw" '/^CONCOURSE_POSTGRES_PASSWORD=/{print "CONCOURSE_POSTGRES_PASSWORD=" p; next} 1' \
            "$CONF/concourse/web.env" > "$CONF/concourse/web.env.tmp2" && \
        chmod 600 "$CONF/concourse/web.env.tmp2" && mv "$CONF/concourse/web.env.tmp2" "$CONF/concourse/web.env" && \
        echo "  ✓ re-mirrored concourse web POSTGRES_PASSWORD"
    ppw=$(sed -n 's/^CONCOURSE_ADD_LOCAL_USER=pipeline:\([^,]*\),.*/\1/p' "$CONF/concourse/web.env" 2>/dev/null | tail -1)
    apw=$(sed -n 's/^CONCOURSE_ADD_LOCAL_USER=[^,]*,agent:\(.*\)$/\1/p' "$CONF/concourse/web.env" 2>/dev/null | tail -1)
    [ -n "$ppw" ] && [ -n "$apw" ] && [ -f "$CONF/concourse/mcp.env" ] && \
        awk -v p="$ppw" -v a="$apw" '/^CONCOURSE_PASSWORD=/{print "CONCOURSE_PASSWORD=" p; next}
             /^CONCOURSE_LOWPRIV_PASSWORD=/{print "CONCOURSE_LOWPRIV_PASSWORD=" a; next} 1' \
            "$CONF/concourse/mcp.env" > "$CONF/concourse/mcp.env.tmp" && \
        chmod 600 "$CONF/concourse/mcp.env.tmp" && mv "$CONF/concourse/mcp.env.tmp" "$CONF/concourse/mcp.env" && \
        echo "  ✓ re-mirrored mcp.env concourse credentials"
fi
if [ "$APPLY" = 1 ]; then
    rand_hex 32 > "$CONF/notebook/jupyter-token" 2>/dev/null && \
        chmod 600 "$CONF/notebook/jupyter-token" && \
        echo "  ✓ rotated notebook/jupyter-token"
fi
if [ "$APPLY" = 1 ]; then
    mp=$(sed -n 's/^MYSQL_PASSWORD=//p' "$CONF/ragflow/service.env" 2>/dev/null | tail -1)
    [ -n "$mp" ] && [ -f "$CONF/ragflow/mysql.env" ] && \
        awk -v p="$mp" '/^MYSQL_ROOT_PASSWORD=/{print "MYSQL_ROOT_PASSWORD=" p; next} 1' \
            "$CONF/ragflow/mysql.env" > "$CONF/ragflow/mysql.env.tmp" && \
        chmod 600 "$CONF/ragflow/mysql.env.tmp" && mv "$CONF/ragflow/mysql.env.tmp" "$CONF/ragflow/mysql.env" && \
        echo "  ✓ re-mirrored ragflow mysql.env"
    pgpw=$(sed -n 's/^POSTGRES_PASSWORD=//p' "$CONF/kb-postgres/service.env" 2>/dev/null | tail -1)
    [ -n "$pgpw" ] && [ -f "$CONF/lightrag/service.env" ] && \
        awk -v p="$pgpw" '/^POSTGRES_PASSWORD=/{print "POSTGRES_PASSWORD=" p; next} 1' \
            "$CONF/lightrag/service.env" > "$CONF/lightrag/service.env.tmp" && \
        chmod 600 "$CONF/lightrag/service.env.tmp" && mv "$CONF/lightrag/service.env.tmp" "$CONF/lightrag/service.env" && \
        echo "  ✓ re-mirrored lightrag POSTGRES_PASSWORD"
    # windmill: the DB password lives inside DATABASE_URL - rewrite that field
    wm_dbpw=$(sed -n 's/^POSTGRES_PASSWORD=//p' "$CONF/windmill-postgres/service.env" 2>/dev/null | tail -1)
    [ -n "$wm_dbpw" ] && [ -f "$CONF/windmill/service.env" ] && \
        awk -v p="$wm_dbpw" '/^DATABASE_URL=/{sub(/:[^:@]*@/, ":" p "@"); print; next} 1' \
            "$CONF/windmill/service.env" > "$CONF/windmill/service.env.tmp" && \
        chmod 600 "$CONF/windmill/service.env.tmp" && mv "$CONF/windmill/service.env.tmp" "$CONF/windmill/service.env" && \
        echo "  ✓ re-mirrored windmill DATABASE_URL password"
fi
# Strata's setup json stores the key too, and it wins over the env: copy the
# new key into every variant's config so all three keep one key.
STRATA_DATA="${HOME}/.local/share/strata"
if [ -f "$CONF/strata/service.env" ]; then
    for cfg in "$STRATA_DATA"/config-*/strata-*.json; do
        [ -f "$cfg" ] || continue
        if [ "$APPLY" = 1 ]; then
            python3 - "$CONF/strata/service.env" "$cfg" <<'EOF'
import json, os, sys
env = dict(l.rstrip("\n").split("=", 1) for l in open(sys.argv[1]) if "=" in l)
cfg = json.load(open(sys.argv[2]))
cfg["api_key"] = env["API_KEY"]
tmp = sys.argv[2] + ".tmp"
with open(tmp, "w") as f:
    json.dump(cfg, f, indent=1)
os.chmod(tmp, 0o600)
os.replace(tmp, sys.argv[2])
EOF
            echo "  ✓ synced API key into $cfg"
        else
            echo "  ~ would sync the new API key into $cfg"
        fi
    done
fi

KEYS="$CONF/llama-cpp/keys.txt"
if [ -f "$KEYS" ]; then
    if [ "$APPLY" = 1 ]; then
        tmp=$(mktemp "${KEYS}.XXXXXX")
        rand 16 > "$tmp"; chmod 600 "$tmp"; mv "$tmp" "$KEYS"
        echo "  ✓ regenerated $KEYS (mode 600)"
    else
        echo "  ~ would regenerate $KEYS"
    fi
fi

if [ "$APPLY" = 1 ]; then
    # Clients carry copies of the strata/llama keys (open-webui, sketchlab, dsh
    # managed lines): install.sh rewrites them from the new values.
    "$ROOT/install.sh" --no-images >/dev/null && echo "  ✓ client env files updated (install.sh --no-images)"
    for svc in open-webui sketchlab deepseek-harness strata-5090 strata-4070ti strata-both \
               llama-cpp-5090 llama-cpp-4070ti llama-cpp-both \
               ragflow-elasticsearch ragflow-mysql ragflow-minio ragflow-kvrocks \
               ragflow kb-postgres lightrag kb-analysis \
               windmill-postgres windmill-server windmill-worker notebook ailab-api \
               forge-postgres forge s3 concourse-postgres concourse-web concourse-worker concourse-mcp; do
        systemctl --user is-active "${svc}.service" &>/dev/null || continue
        systemctl --user restart "${svc}.service" && echo "  ✓ restarted $svc"
    done
    echo "Done. Update any client configs that referenced the old keys."
else
    echo "  ~ would update the client copies of the keys (install.sh --no-images:"
    echo "    open-webui, sketchlab, deepseek-harness if its env exists) and restart"
    echo "    the active services"
    echo ""
    echo "Re-run with --yes to apply and restart affected services."
fi
