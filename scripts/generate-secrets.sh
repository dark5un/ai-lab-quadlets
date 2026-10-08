#!/usr/bin/env bash
# generate-secrets.sh — create the stack's secret-bearing env files from the
# repo's .example templates, straight into the runtime config dir. Existing
# files are kept (their secrets are live); --force regenerates them.
#
#   ./scripts/generate-secrets.sh [--force] [--with-hermes]
#
# Writes (dirs 700, files 600) under $AI_LAB_CONFIG_DIR
# (default ~/.config/containers/config):
#   open-webui/service.env       WEBUI_SECRET_KEY
#   llama-cpp/keys.txt           API key shared by every llama.cpp server
#   hermes-service/service.env   only with --with-hermes (opt-in container)
# Strata's API key is created by install-strata.sh.
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
CONF="${AI_LAB_CONFIG_DIR:-${HOME}/.config/containers/config}"
FORCE=0 WITH_HERMES=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        --with-hermes) WITH_HERMES=1 ;;
        *) printf 'Unknown option: %s (supported: --force --with-hermes)\n' "$arg" >&2; exit 2 ;;
    esac
done

rand_hex() { openssl rand -hex "${1:-32}"; }

want() {  # want <dst>: true when the file must be (re)generated
    [ ! -f "$1" ] || [ "$FORCE" = 1 ]
}

mkdir -p "$CONF"
chmod 700 "$CONF"

# Open WebUI session secret.
dst="$CONF/open-webui/service.env"
mkdir -p "$(dirname "$dst")"; chmod 700 "$(dirname "$dst")"
if want "$dst"; then
    sed "s/change-me-to-a-random-hex-string/$(rand_hex 32)/" \
        "$ROOT/config/open-webui/service.env.example" > "$dst"
    echo "  created $dst"
else
    echo "  kept    $dst"
fi
chmod 600 "$dst"

# llama.cpp API key (LLAMA_ARG_API_KEY_FILE of every llama.cpp server).
dst="$CONF/llama-cpp/keys.txt"
mkdir -p "$(dirname "$dst")"; chmod 700 "$(dirname "$dst")"
if want "$dst"; then
    rand_hex 16 > "$dst"
    echo "  created $dst"
else
    echo "  kept    $dst"
fi
chmod 600 "$dst"

# Containerized Hermes gateway (opt-in; this host runs Hermes natively).
if [ "$WITH_HERMES" = 1 ]; then
    dst="$CONF/hermes-service/service.env"
    mkdir -p "$(dirname "$dst")"; chmod 700 "$(dirname "$dst")"
    if want "$dst"; then
        sed -e "s/change-me-to-a-random-hex-string/$(rand_hex 16)/" \
            -e "s/change-me-to-another-random-hex-string/$(rand_hex 32)/" \
            "$ROOT/config/hermes-service/service.env.example" > "$dst"
        echo "  created $dst (dashboard password stored in this file)"
    else
        echo "  kept    $dst"
    fi
    chmod 600 "$dst"
fi
