#!/usr/bin/env bash
# install-strata.sh — build the Strata image and install the strata GPU
# variants (strata-5090 and strata-4070ti at 256K / 524K / 1M context,
# strata-both at 256K: one at a time) and the coder (Coder IQ1_M on the 4070 Ti
# at 256K / 524K / 1M, one at a time, can run beside a 5090 variant) as user
# quadlets.
#
#   ./scripts/install-strata.sh            build the image if missing, render units
#   ./scripts/install-strata.sh --rebuild  rebuild localhost/strata:multi first
#
# Nothing is started here; only strata-5090-1m (the default variant) is
# enabled at boot by install.sh. Switch with
#   ai-lab strata <variant>|duo|off`, `scripts/ai-lab coder 128k|256k|524k|1m|off` or the
# AI Lab bar widget.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRATA_REPO="${STRATA_REPO:-${HOME}/workspace/github.com/dark5un/strata-harness}"
IMAGE="localhost/strata-harness:multi"
CUDA_ARCHS="120;89"   # RTX 5090 = sm_120, RTX 4070 Ti = sm_89
VARIANTS=(5090 5090-524k 5090-1m 4070ti 4070ti-524k 4070ti-1m both coder coder-128k coder-524k coder-1m)
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
    [[ -f "$STRATA_REPO/Dockerfile" && -f "$STRATA_REPO/docker/entrypoint.sh" ]] || {
        printf 'Strata checkout not found at %s (set STRATA_REPO).\n' "$STRATA_REPO" >&2
        exit 1
    }
    printf 'Building %s from %s (CUDA %s)...\n' "$IMAGE" "$STRATA_REPO" "$CUDA_ARCHS"
    # 0.2.0 Dockerfile: the base images are build ARGs (CUDA_IMAGE, RUNTIME_BASE);
    # podman has no short-name alias for nvidia/cuda, so qualify both via
    # --build-arg and build the upstream Dockerfile as-is (no temp copy, no sed).
    podman build --build-arg "CUDA_ARCHITECTURES=${CUDA_ARCHS}" \
        --build-arg "CUDA_IMAGE=docker.io/nvidia/cuda:13.0.0-devel-ubuntu24.04" \
        --build-arg "RUNTIME_BASE=docker.io/library/ubuntu:24.04" \
        -t "$IMAGE" -f "$STRATA_REPO/Dockerfile" "$STRATA_REPO"
else
    printf 'Image %s exists (use --rebuild to rebuild).\n' "$IMAGE"
fi

# --- Shared settings + API key ---------------------------------------------------
mkdir -p "$QUADLET_DIR" "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"
SERVICE_ENV="$CONFIG_DIR/service.env"
if [[ ! -e "$SERVICE_ENV" ]]; then
    umask 077
    printf 'FAMILY=qwen\nMODEL=IQ3_S\nVISION=cpu\nAPI_KEY=%s\n' \
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

# --- Data layout: shared model data + 0.2.0 state dirs, one preset store per variant
mkdir -p "$DATA_DIR"/{models,mtp,packs,workspaces,state,install,home}
for v in "${VARIANTS[@]}"; do mkdir -p "$DATA_DIR/config-$v"; chmod 700 "$DATA_DIR/config-$v"; done
chmod 700 "$DATA_DIR"
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
# The 0.1.x setup configs (config-<v>/strata-*.json) are NOT read by the 0.2.0
# image (it uses named presets under /data/config); they are left on disk as a
# rollback aid while the multi-0144-backup image exists.

# --- Units -------------------------------------------------------------------------
# GPU UUIDs are filled in by name from nvidia-smi (never by index).
"$ROOT/scripts/render-units.sh" ai strata-5090 strata-5090-524k strata-5090-1m strata-4070ti strata-4070ti-524k \
    strata-4070ti-1m strata-both strata-coder strata-coder-128k strata-coder-524k strata-coder-1m

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
printf 'Switch:   %s/scripts/ai-lab strata 5090[-524k|-1m]|4070ti[-524k|-1m]|both|duo|off\n' "$ROOT"
printf 'Coder:    %s/scripts/ai-lab coder 128k|256k|524k|1m|off\n' "$ROOT"
printf 'API:      http://<host>:11434/v1, coder http://<host>:11439/v1 (API key in %s)\n' "$SERVICE_ENV"
printf 'Clients:  http://systemd-strata:8080/v1 on the systemd-ai network\n'
printf 'A variant whose config-<v>/ holds no preset named strata-<v> runs `strata launch` setup on its first start (model files found via MODEL_PATH=/data/models).\n'
