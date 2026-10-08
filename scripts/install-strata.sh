#!/usr/bin/env bash
# install-strata.sh — build the Strata image and install the strata GPU
# variants (strata-5090 at 256K / 524K / 1M context, strata-4070ti,
# strata-both: one at a time) and strata-coder (Coder IQ1_M on the 4070 Ti,
# can run beside a 5090 variant) as user quadlets.
#
#   ./scripts/install-strata.sh            build the image if missing, render units
#   ./scripts/install-strata.sh --rebuild  rebuild localhost/strata:multi first
#
# Nothing is started and nothing is enabled at boot: switch with
# `scripts/ai-lab strata 5090|5090-524k|5090-1m|4070ti|both|duo|off` or the
# AI Lab bar widget.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRATA_REPO="${STRATA_REPO:-${HOME}/workspace/github.com/Niko1221/Strata}"
IMAGE="localhost/strata:multi"
CUDA_ARCHS="120;89"   # RTX 5090 = sm_120, RTX 4070 Ti = sm_89
VARIANTS=(5090 5090-524k 5090-1m 4070ti both coder)
QUADLET_DIR="${HOME}/.config/containers/systemd"
CONFIG_DIR="${HOME}/.config/containers/config/strata"
DATA_DIR="${HOME}/.local/share/strata"
REBUILD=0

for arg in "$@"; do
    case "$arg" in
        --rebuild) REBUILD=1 ;;
        *) printf 'Unknown option: %s (supported: --rebuild)\n' "$arg" >&2; exit 2 ;;
    esac
done

for cmd in podman nvidia-smi openssl systemctl awk sed; do
    command -v "$cmd" >/dev/null 2>&1 || { printf 'Required command not found: %s\n' "$cmd" >&2; exit 1; }
done

# --- Image ---------------------------------------------------------------------
if [[ "$REBUILD" == 1 ]] || ! podman image exists "$IMAGE"; then
    [[ -f "$STRATA_REPO/Dockerfile" && -f "$STRATA_REPO/docker-entrypoint.sh" ]] || {
        printf 'Strata checkout not found at %s (set STRATA_REPO).\n' "$STRATA_REPO" >&2
        exit 1
    }
    printf 'Building %s from %s (CUDA %s)...\n' "$IMAGE" "$STRATA_REPO" "$CUDA_ARCHS"
    BUILD_TMP="${TMPDIR:-${HOME}/.cache/ai-lab-quadlets}"
    mkdir -p "$BUILD_TMP"
    BUILD_DIR="$(mktemp -d "$BUILD_TMP/strata-build.XXXXXX")"
    trap 'rm -rf "$BUILD_DIR"' EXIT
    # Podman has no short-name alias for nvidia/cuda here: qualify the base
    # image in a temporary copy, leaving the Strata checkout untouched.
    sed 's|^FROM nvidia/cuda:|FROM docker.io/nvidia/cuda:|' "$STRATA_REPO/Dockerfile" > "$BUILD_DIR/Containerfile"
    grep -q '^FROM docker.io/nvidia/cuda:' "$BUILD_DIR/Containerfile" || {
        printf 'Could not qualify the Strata Dockerfile base image for Podman.\n' >&2; exit 1; }
    podman build --build-arg "CUDA_ARCHITECTURES=${CUDA_ARCHS}" -t "$IMAGE" \
        -f "$BUILD_DIR/Containerfile" "$STRATA_REPO"
    rm -rf "$BUILD_DIR"
    trap - EXIT
else
    printf 'Image %s exists (use --rebuild to rebuild).\n' "$IMAGE"
fi

# --- Shared settings + API key ---------------------------------------------------
mkdir -p "$QUADLET_DIR" "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"
SERVICE_ENV="$CONFIG_DIR/service.env"
if [[ ! -e "$SERVICE_ENV" ]]; then
    umask 077
    printf 'FAMILY=qwen\nMODEL=IQ3_S\nVISION=no\nLOW_RAM=auto\nAPI_KEY=%s\n' \
        "$(openssl rand -hex 32)" > "$SERVICE_ENV"
    printf '  created %s with a new API key\n' "$SERVICE_ENV"
elif ! grep -Eq '^API_KEY=[^[:space:]]+' "$SERVICE_ENV"; then
    printf '%s has no API_KEY; add a non-empty key first.\n' "$SERVICE_ENV" >&2
    exit 1
fi
# GPU / GPUS / CONTEXT / KV are per variant now (Environment= in each unit).
if grep -Eq '^(GPU|GPUS|CONTEXT|KV)=' "$SERVICE_ENV"; then
    sed -i -E '/^(GPU|GPUS|CONTEXT|KV)=/d' "$SERVICE_ENV"
    printf '  removed per-variant keys (GPU/GPUS/CONTEXT/KV) from %s\n' "$SERVICE_ENV"
fi
chmod 600 "$SERVICE_ENV"

# --- Data layout: shared model data, one setup config dir per variant -----------
mkdir -p "$DATA_DIR"/{models,mtp,packs}
for v in "${VARIANTS[@]}"; do mkdir -p "$DATA_DIR/config-$v"; chmod 700 "$DATA_DIR/config-$v"; done
chmod 700 "$DATA_DIR"
# Strata's setup writes strata-*.json (it holds the API key) 644; later rewrites
# keep the mode, so tightening it once sticks.
find "$DATA_DIR"/config-* -maxdepth 1 -name 'strata-*.json' -exec chmod 600 {} +
# A single-unit install kept its setup in config/: that one ran on the 5090.
if [[ -d "$DATA_DIR/config" ]]; then
    if [[ -z "$(ls -A "$DATA_DIR/config-5090")" ]]; then
        mv "$DATA_DIR/config/"* "$DATA_DIR/config-5090/" 2>/dev/null || true
        rmdir "$DATA_DIR/config" 2>/dev/null || true
        printf '  moved legacy config/ to config-5090/\n'
    else
        printf '  note: legacy %s/config left in place (config-5090 is not empty)\n' "$DATA_DIR"
    fi
fi

# --- Units -------------------------------------------------------------------------
# GPU UUIDs are filled in by name from nvidia-smi (never by index).
"$ROOT/scripts/render-units.sh" ai strata-5090 strata-5090-524k strata-5090-1m strata-4070ti strata-both strata-coder

# --- strata-coder's setup config ------------------------------------------------------
# The coder runs pinned to the last 8 CPUs, so its --pool-workers must be 7
# (pinned cores - 1; workers == cores halves decode). Strata's setup writes 15
# on this CPU and only on the first start, so the config is prepared here: a
# copy of an existing coder setup, or a setup run in a one-off container
# (downloads the ~58 GB Coder files if they are missing; nothing is served).
CODER_CFG="$DATA_DIR/config-coder/strata-coder-iq1_m.json"
CODER_WORKERS=7
if [[ ! -f "$CODER_CFG" ]]; then
    if [[ -f "$DATA_DIR/config-4070ti/strata-coder-iq1_m.json" ]]; then
        cp "$DATA_DIR/config-4070ti/strata-coder-iq1_m.json" "$CODER_CFG"
        printf '  strata-coder: config copied from config-4070ti\n'
    else
        printf '  strata-coder: running Strata setup (Coder IQ1_M; downloads if needed)...\n'
        UUID_4070TI="$(nvidia-smi --query-gpu=name,uuid --format=csv,noheader | awk -F, '/RTX 4070 Ti/ {gsub(/ /, "", $2); print $2; exit}')"
        podman run --rm --device "nvidia.com/gpu=$UUID_4070TI" --security-opt label=disable \
            --env-file "$SERVICE_ENV" \
            -v "$DATA_DIR/models:/data/models" -v "$DATA_DIR/mtp:/data/mtp" -v "$DATA_DIR/packs:/data/packs" \
            -v "$DATA_DIR/config-coder:/data/config" \
            --entrypoint sh "$IMAGE" -c '
              set -e; cd /opt/strata
              .venv/bin/python setup.py --setup --yes --family coder --model IQ1_M --context 262144 \
                --vision no --data-dir /data --host 0.0.0.0 --api-key "$API_KEY" --port 8080 --no-start \
                --low-ram "$LOW_RAM" --kv int8 --gpu 0
              cp -f /opt/strata/strata-coder-iq1_m.json /data/config/strata-coder-iq1_m.json'
    fi
fi
if [[ -f "$CODER_CFG" ]]; then
    python3 - "$CODER_CFG" "$CODER_WORKERS" <<'PYEOF'
import json, sys
path, n = sys.argv[1], sys.argv[2]
cfg = json.load(open(path))
args = cfg["args"]
if "--pool-workers" in args:
    args[args.index("--pool-workers") + 1] = n
else:
    args += ["--pool-workers", n]
json.dump(cfg, open(path, "w"), indent=1)
PYEOF
    chmod 600 "$CODER_CFG"
    printf '  strata-coder: --pool-workers %s\n' "$CODER_WORKERS"
fi
# Retire the single-GPU unit of earlier installs.
if [[ -f "$QUADLET_DIR/strata.container" ]]; then
    systemctl --user stop strata.service 2>/dev/null || true
    rm -f "$QUADLET_DIR/strata.container"
    printf '  removed legacy strata.container\n'
fi
# podman 6 makes every quadlet wait for podman-user-wait-network-online.service,
# which times out on Arch (the system network-online.target never activates)
# and blocks the start for minutes. The stack is local-only: mask it.
# uninstall.sh unmasks it again.
systemctl --user mask podman-user-wait-network-online.service >/dev/null 2>&1 || true
# install.sh sets AI_LAB_NO_RELOAD=1 and reloads once at its end.
[ "${AI_LAB_NO_RELOAD:-0}" = 1 ] || systemctl --user daemon-reload

printf '\nStrata variants installed (none started, none at boot):\n'
printf 'Switch:   %s/scripts/ai-lab strata 5090|5090-524k|5090-1m|4070ti|both|duo|off\n' "$ROOT"
printf 'API:      http://<host>:11434/v1, coder http://<host>:11439/v1 (API key in %s)\n' "$SERVICE_ENV"
printf 'Clients:  http://systemd-strata:8080/v1 on the systemd-ai network\n'
printf 'A variant whose config-<v>/ is empty runs Strata setup on its first start.\n'
