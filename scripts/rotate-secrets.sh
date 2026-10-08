#!/usr/bin/env bash
# rotate-secrets.sh — regenerate leaked/unknown secrets and restart what uses them.
#
#   ./scripts/rotate-secrets.sh [--yes]
#
# Rotates:
#   - open-webui WEBUI_SECRET_KEY   (config/open-webui/service.env)
#   - llama.cpp API keys            (config/llama.cpp/keys.txt)
#   - strata API_KEY                (config/strata/service.env + every
#                                    ~/.local/share/strata/config-*/strata-*.json)
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

KEYS="$CONF/llama.cpp/keys.txt"
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
    for svc in open-webui strata-5090 strata-4070ti strata-both llama-cpp-main; do
        systemctl --user is-active "${svc}.service" &>/dev/null || continue
        systemctl --user restart "${svc}.service" && echo "  ✓ restarted $svc"
    done
    echo "Done. Update any client configs that referenced the old keys."
else
    echo ""
    echo "Re-run with --yes to apply and restart affected services."
fi
