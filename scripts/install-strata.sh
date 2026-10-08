#!/usr/bin/env bash
# install-strata.sh — build the Strata image and install the three GPU
# variants (strata-5090, strata-4070ti, strata-both) as user quadlets.
#
#   ./scripts/install-strata.sh            build the image if missing, render units
#   ./scripts/install-strata.sh --rebuild  rebuild localhost/strata:multi first
#
# Nothing is started and nothing is enabled at boot: switch with
# `scripts/ai-lab strata 5090|4070ti|both|off` or the AI Lab bar widget.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRATA_REPO="${STRATA_REPO:-${HOME}/workspace/github.com/Niko1221/Strata}"
IMAGE="localhost/strata:multi"
CUDA_ARCHS="120;89"   # RTX 5090 = sm_120, RTX 4070 Ti = sm_89
VARIANTS=(5090 4070ti both)
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
for v in "${VARIANTS[@]}"; do mkdir -p "$DATA_DIR/config-$v"; done
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

# --- Units -------------------------------------------------------------------------
# GPU UUIDs are filled in by name from nvidia-smi (never by index).
"$ROOT/scripts/render-units.sh" ai strata-5090 strata-4070ti strata-both
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
systemctl --user daemon-reload

printf '\nStrata variants installed (none started, none at boot):\n'
printf 'Switch:   %s/scripts/ai-lab strata 5090|4070ti|both|off\n' "$ROOT"
printf 'API:      http://<host>:11434/v1 (API key in %s)\n' "$SERVICE_ENV"
printf 'Clients:  http://systemd-strata:8080/v1 on the systemd-ai network\n'
printf 'A variant whose config-<v>/ is empty runs Strata setup on its first start.\n'
