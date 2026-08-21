#!/usr/bin/env bash
# build-images.sh — Ensure custom container images required by the quadlets
#
# Tries GHCR pre-built images first, falls back to local builds.
# Tags everything as localhost/ so quadlets find them.
#
# Usage:
#   ./scripts/build-images.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== AI Lab Quadlet — Custom Images ===="
echo ""

# ─── Sketch Lab ───────────────────────────────────────────────────────────
echo "1) Ensuring sketchlab image (localhost/sketchlab:v0.5.0)..."
if podman image exists localhost/sketchlab:v0.5.0 2>/dev/null; then
    echo "   ✓ Already exists"
elif podman pull ghcr.io/dark5un/sketchlab:v0.5.0 2>/dev/null; then
    podman tag ghcr.io/dark5un/sketchlab:v0.5.0 localhost/sketchlab:v0.5.0 2>/dev/null || true
    echo "   ✓ Pulled from GHCR"
elif [ -d "$HOME/sketchlab.app" ]; then
    echo "   Building from local clone..."
    (cd "$HOME/sketchlab.app" && podman build -t localhost/sketchlab:v0.5.0 .) && \
        echo "   ✓ Built" || echo "   ! Build failed"
elif command -v git &>/dev/null; then
    TMP=$(mktemp -d /tmp/sketchlab-XXXXX)
    echo "   Cloning and building from source..."
    git clone --depth=1 https://github.com/dark5un/sketchlab.app.git "$TMP" 2>/dev/null && \
        (cd "$TMP" && podman build -t localhost/sketchlab:v0.5.0 .) && \
        echo "   ✓ Built" || echo "   ! Build failed"
    rm -rf "$TMP" 2>/dev/null || true
else
    echo "   ! Sketch Lab image unavailable. See README.md for build instructions."
fi
echo ""

# ─── ComfyUI ──────────────────────────────────────────────────────────────
echo "2) ComfyUI (localhost/comfyui:v0.30.2-cu130)..."
if podman image exists localhost/comfyui:v0.30.2-cu130 2>/dev/null; then
    echo "   ✓ Already exists"
elif [ -f "${PROJECT_DIR}/containers/comfyui/Containerfile" ]; then
    echo "   Building from containers/comfyui/ ..."
    podman build -t localhost/comfyui:v0.30.2-cu130 \
        -f "${PROJECT_DIR}/containers/comfyui/Containerfile" \
        "${PROJECT_DIR}/containers/comfyui/" && echo "   ✓ Built"
else
    echo "   ~ No custom Containerfile — will use pre-built image from Docker Hub."
fi
echo ""

echo "=== Image check complete ==="