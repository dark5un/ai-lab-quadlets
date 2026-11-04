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
#   openviking/service.env       root API key (memory group)
#   honcho/service.env           DB password + JWT secret (memory group)
#   dufs/config.yaml + service.env  WebDAV px password (hashed + plaintext mirror)
#   vscode/service.env           VSCODE_CONNECTION_TOKEN (serve-web)
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

# Grafana admin password (monitoring tier; GF_SECURITY_ADMIN_PASSWORD).
dst="$CONF/grafana/service.env"
mkdir -p "$(dirname "$dst")"; chmod 700 "$(dirname "$dst")"
if [ ! -f "$dst" ] && [ -f "$ROOT/config/grafana/service.env.example" ]; then
    sed "s/change-me-to-a-random-hex-string/$(rand_hex 16)/" \
        "$ROOT/config/grafana/service.env.example" > "$dst"
    echo "  created $dst"
fi
chmod 600 "$dst"

# OpenViking root API key (server.root_api_key; install.sh renders it into
# ov.conf from the same file).
dst="$CONF/openviking/service.env"
mkdir -p "$(dirname "$dst")"; chmod 700 "$(dirname "$dst")"
if want "$dst"; then
    sed "s/change-me-to-a-random-hex-string/$(rand_hex 32)/" \
        "$ROOT/config/openviking/service.env.example" > "$dst"
    echo "  created $dst"
else
    echo "  kept    $dst"
fi
chmod 600 "$dst"

# Honcho (memory group): one DB password reused in POSTGRES_PASSWORD and in
# DB_CONNECTION_URI, plus the JWT signing secret. The strata/llama.cpp LLM
# keys are managed lines rewritten by install.sh.
dst="$CONF/honcho/service.env"
mkdir -p "$(dirname "$dst")"; chmod 700 "$(dirname "$dst")"
if want "$dst"; then
    sed -e "s/change-me-to-a-random-hex-string/$(rand_hex 16)/g" \
        -e "s/change-me-to-another-random-hex-string/$(rand_hex 32)/" \
        "$ROOT/config/honcho/service.env.example" > "$dst"
    echo "  created $dst"
else
    echo "  kept    $dst"
fi
chmod 600 "$dst"

# dufs WebDAV (files tier): sha-512 hashed password for the px account in
# the mounted config.yaml; the plaintext lives only in dufs/service.env
# (DAV_PASSWORD) so clients can be configured. The hash never touches argv.
dst="$CONF/dufs/config.yaml"
mkdir -p "$(dirname "$dst")"; chmod 700 "$(dirname "$dst")"
if want "$dst"; then
    dav_pass="$(openssl rand -hex 16)"
    dav_hash="$(openssl passwd -6 "$dav_pass")"
    sed "s|change-me-to-a-random-hashed-password|$dav_hash|" \
        "$ROOT/config/dufs/config.yaml.example" > "$dst"
    printf 'DAV_USER=px\nDAV_PASSWORD=%s\n' "$dav_pass" > "$CONF/dufs/service.env"
    echo "  created $dst (user px; password in dufs/service.env, not printed)"
else
    echo "  kept    $dst"
fi
chmod 600 "$dst" "$CONF/dufs/service.env"

# VS Code Server (serve-web) connection token + strata BYOK key for the box.
dst="$CONF/vscode/service.env"
mkdir -p "$(dirname "$dst")"; chmod 700 "$(dirname "$dst")"
if want "$dst"; then
    sed "s/change-me-to-a-random-hex-string/$(rand_hex 16)/" \
        "$ROOT/config/vscode/service.env.example" > "$dst"
    echo "  created $dst"
else
    echo "  kept    $dst"
fi
# Copy the live strata key (created by install-strata.sh) into the vscode
# env when that line is empty/missing -- same pattern as sketchlab's
# STRATA_API_KEY. Never prints the value.
if [ -f "$CONF/strata/service.env" ] && ! grep -q '^STRATA_API_KEY=..' "$dst"; then
    sk=$(sed -n 's/^API_KEY=//p' "$CONF/strata/service.env" | head -1)
    if [ -n "$sk" ]; then
        if grep -q '^STRATA_API_KEY=' "$dst"; then
            # awk with -v, not sed: a key containing & or | would corrupt a
            # sed replacement (review finding #12). Generated keys are hex,
            # but these files are hand-editable.
            awk -v k="$sk" '/^STRATA_API_KEY=/{print "STRATA_API_KEY=" k; next} 1' "$dst" > "$dst.tmp" && mv "$dst.tmp" "$dst"
        else
            printf 'STRATA_API_KEY=%s\n' "$sk" >> "$dst"
        fi
        echo "  synced STRATA_API_KEY into $dst from config/strata/service.env"
    fi
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
