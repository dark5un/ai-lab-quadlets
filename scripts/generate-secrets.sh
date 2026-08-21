#!/usr/bin/env bash
# generate-secrets.sh — Generate random secrets for service .env files
#
# Creates production-ready .env files from the .example templates,
# filling in random hex strings for secrets that need them.
#
# Usage:
#   ./scripts/generate-secrets.sh [--force]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

FORCE=false
if [ "${1:-}" = "--force" ]; then
    FORCE=true
fi

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

# ─── Hermes Agent ─────────────────────────────────────────────────────────
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
        echo "  Created: $DST"
        echo "  Dashboard password: $PASSWORD"
    else
        echo "  SKIP: $SRC not found"
    fi
else
    echo "  EXISTS: $DST (use --force to regenerate)"
fi

# ─── llama.cpp API key ────────────────────────────────────────────────────
DST="${PROJECT_DIR}/config/llama.cpp/keys.txt"
if [ ! -f "$DST" ] || [ "$FORCE" = true ]; then
    echo "$(rand_hex 16)" > "$DST"
    echo "  Created: $DST"
else
    echo "  EXISTS: $DST (use --force to regenerate)"
fi

echo ""
echo "=== Secret generation complete ==="
echo "Run the following to copy configs to their runtime location:"
echo "  mkdir -p ~/.config/containers/config"
echo "  cp -r config/* ~/.config/containers/config/"