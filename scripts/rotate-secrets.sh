#!/usr/bin/env bash
# rotate-secrets.sh — regenerate leaked/unknown secrets and restart what uses them.
#
#   ./scripts/rotate-secrets.sh [--yes]
#
# Rotates:
#   - open-webui WEBUI_SECRET_KEY   (config/open-webui/service.env)
#   - llama.cpp API keys            (config/llama.cpp/keys.txt)
#   - strata API_KEY                (config/strata/service.env)  [if present]
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
    for svc in open-webui strata llama-cpp-main; do
        systemctl --user is-active "${svc}.service" &>/dev/null || continue
        systemctl --user restart "${svc}.service" && echo "  ✓ restarted $svc"
    done
    echo "Done. Update any client configs that referenced the old keys."
else
    echo ""
    echo "Re-run with --yes to apply and restart affected services."
fi
