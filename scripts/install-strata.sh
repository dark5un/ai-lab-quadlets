#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRATA_REPO="${STRATA_REPO:-${HOME}/workspace/github.com/Niko1221/Strata}"
IMAGE="localhost/strata:rtx5090"
QUADLET_DIR="${HOME}/.config/containers/systemd"
CONFIG_DIR="${HOME}/.config/containers/config/strata"
DATA_DIR="${HOME}/.local/share/strata"
START_AFTER_INSTALL=0

for arg in "$@"; do
    case "$arg" in
        --start) START_AFTER_INSTALL=1 ;;
        *) printf 'Unknown option: %s (supported: --start)\n' "$arg" >&2; exit 2 ;;
    esac
done

for cmd in podman nvidia-smi openssl systemctl awk sed; do
    command -v "$cmd" >/dev/null 2>&1 || {
        printf 'Required command not found: %s\n' "$cmd" >&2
        exit 1
    }
done

if [[ ! -f "$STRATA_REPO/Dockerfile" || ! -f "$STRATA_REPO/docker-entrypoint.sh" ]]; then
    printf 'Strata checkout not found at %s (set STRATA_REPO to its path).\n' "$STRATA_REPO" >&2
    exit 1
fi

GPU_UUID="$(nvidia-smi --query-gpu=name,uuid --format=csv,noheader | awk -F, '
    /RTX 5090/ {
        uuid=$2
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", uuid)
        print uuid
        exit
    }')"
if [[ -z "$GPU_UUID" ]]; then
    printf 'No RTX 5090 found; this Quadlet is explicitly pinned to that GPU.\n' >&2
    exit 1
fi

printf 'Building %s from %s for CUDA architecture 120...\n' "$IMAGE" "$STRATA_REPO"
BUILD_TMP="${TMPDIR:-${HOME}/.cache/ai-lab-quadlets}"
mkdir -p "$BUILD_TMP"
BUILD_DIR="$(mktemp -d "$BUILD_TMP/strata-build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
CONTAINERFILE="$BUILD_DIR/Containerfile"
# Podman has no configured short-name alias on this host. Qualify the base
# image in a temporary copy, leaving the user's Strata checkout untouched.
sed 's|^FROM nvidia/cuda:|FROM docker.io/nvidia/cuda:|' "$STRATA_REPO/Dockerfile" > "$CONTAINERFILE"
if ! grep -q '^FROM docker.io/nvidia/cuda:' "$CONTAINERFILE"; then
    printf 'Could not qualify Strata Dockerfile base image for Podman.\n' >&2
    exit 1
fi
podman build \
    --build-arg CUDA_ARCHITECTURES=120 \
    -t "$IMAGE" \
    -f "$CONTAINERFILE" \
    "$STRATA_REPO"
rm -rf "$BUILD_DIR"
trap - EXIT

mkdir -p "$QUADLET_DIR" "$CONFIG_DIR" "$DATA_DIR"
chmod 700 "$CONFIG_DIR" "$DATA_DIR"

SERVICE_ENV="$CONFIG_DIR/service.env"
if [[ ! -e "$SERVICE_ENV" ]]; then
    API_KEY="$(openssl rand -hex 32)"
    umask 077
    printf 'FAMILY=qwen\nMODEL=IQ3_S\nCONTEXT=262144\nVISION=no\nGPU=0\nLOW_RAM=auto\nAPI_KEY=%s\n' \
        "$API_KEY" > "$SERVICE_ENV"
    chmod 600 "$SERVICE_ENV"
    unset API_KEY
elif ! grep -Eq '^API_KEY=[^[:space:]]+' "$SERVICE_ENV"; then
    printf 'Existing %s has no API_KEY; add a non-empty key before starting Strata.\n' "$SERVICE_ENV" >&2
    exit 1
fi
chmod 600 "$SERVICE_ENV"

TEMPLATE="$ROOT/quadlets/strata.container.in"
UNIT_TMP="$(mktemp "${QUADLET_DIR}/.strata.container.XXXXXX")"
trap 'rm -f "$UNIT_TMP"' EXIT
sed "s/__STRATA_GPU_UUID__/${GPU_UUID}/g" "$TEMPLATE" > "$UNIT_TMP"
install -m 0644 "$UNIT_TMP" "$QUADLET_DIR/strata.container"
rm -f "$UNIT_TMP"
trap - EXIT

if ! podman network exists systemd-ai 2>/dev/null; then
    # The ai.network Quadlet generates this network as "systemd-ai"; creating
    # "ai.network" by hand would make an orphan.
    podman network create systemd-ai
fi
systemctl --user daemon-reload

printf '\nStrata image and Quadlet are ready.\n'
printf 'Persistent model data: %s\n' "$DATA_DIR"
printf 'API key is stored (mode 0600) in: %s\n' "$SERVICE_ENV"
printf 'API: http://127.0.0.1:11434/v1 locally (host bind: 0.0.0.0, LAN; every request needs the API key)\n'
printf 'Other ai.network containers: http://systemd-strata:8080/v1\n'
printf 'The first start downloads about 84 GB of IQ3_S model data.\n'
if [[ "$START_AFTER_INSTALL" == 1 ]]; then
    systemctl --user start strata.service
else
    printf 'Not starting automatically; run systemctl --user start strata.service when ready.\n'
fi
