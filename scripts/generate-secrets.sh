#!/usr/bin/env bash
# generate-secrets.sh — Generate random secrets for service .env files
#
# Creates production-ready .env files from the .example templates,
# filling in random hex strings for secrets that need them.
#
# Usage:
#   ./scripts/generate-secrets.sh [--force] [--with-hermes]

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

FORCE=false
WITH_HERMES=false
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=true ;;
        --with-hermes) WITH_HERMES=true ;;
        *) printf 'Unknown option: %s (supported: --force --with-hermes)\n' "$arg" >&2; exit 2 ;;
    esac
done

# Generate a random hex string of given byte length
rand_hex() {
    local bytes="${1:-32}"
    openssl rand -hex "$bytes"
}

echo "=== Generating secrets for AI Lab Quadlets ==="
echo ""

# ─── Open WebUI ───────────────────────────────────────────────────────────
SRC="${PROJECT_DIR}/config/open-webui/service.env.example"
DST="${PROJECT_DIR}/config/open-webui/service.env"
if [ ! -f "$DST" ] || [ "$FORCE" = true ]; then
    if [ -f "$SRC" ]; then
        sed "s/change-me-to-a-random-hex-string/$(rand_hex 32)/" "$SRC" > "$DST"
        echo "  Created: $DST"
    else
        echo "  SKIP: $SRC not found"
    fi
else
    echo "  EXISTS: $DST (use --force to regenerate)"
fi
[ ! -f "$DST" ] || chmod 600 "$DST"

# ─── Containerized Hermes gateway (opt-in; not the host Hermes Agent) ──────
if [ "$WITH_HERMES" = true ]; then
    SRC="${PROJECT_DIR}/config/hermes-service/service.env.example"
    DST="${PROJECT_DIR}/config/hermes-service/service.env"
    if [ ! -f "$DST" ] || [ "$FORCE" = true ]; then
        if [ -f "$SRC" ]; then
            PASSWORD=$(rand_hex 16)
            SECRET=$(rand_hex 32)
            sed \
                -e "s/change-me-to-a-random-hex-string/$PASSWORD/" \
                -e "s/change-me-to-another-random-hex-string/$SECRET/" \
                "$SRC" > "$DST"
            chmod 600 "$DST"
            unset PASSWORD SECRET
            echo "  Created: $DST (dashboard password stored in this file)"
        else
            echo "  SKIP: $SRC not found"
        fi
    else
        echo "  EXISTS: $DST (use --force to regenerate)"
    fi
    [ ! -f "$DST" ] || chmod 600 "$DST"
else
    echo "  SKIP: containerized Hermes gateway (use --with-hermes to generate its config)"
fi

# ─── llama.cpp API key ────────────────────────────────────────────────────
DST="${PROJECT_DIR}/config/llama.cpp/keys.txt"
if [ ! -f "$DST" ] || [ "$FORCE" = true ]; then
    echo "$(rand_hex 16)" > "$DST"
    echo "  Created: $DST"
else
    echo "  EXISTS: $DST (use --force to regenerate)"
fi
[ ! -f "$DST" ] || chmod 600 "$DST"

echo ""
echo "=== Secret generation complete ==="
echo "Run the following to copy configs to their runtime location:"
echo "  mkdir -p ~/.config/containers/config"
echo "  cp -r config/* ~/.config/containers/config/"