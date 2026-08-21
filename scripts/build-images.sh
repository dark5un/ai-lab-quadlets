#!/usr/bin/env bash
# build-images.sh — Build custom container images required by the quadlets
#
# Builds:
#   - localhost/sketchlab:v0.5.0     (from containers/sketchlab/)
#   - localhost/comfyui:v0.30.2-cu130  (from containers/comfyui/, if present)
#
# Prerequisites: podman with nvidia-container-toolkit (for the CUDA image).
# Usage:
#   ./scripts/build-images.sh [--comfyui-source /path/to/ComfyUI]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Building AI Lab Quadlet Custom Images ==="
echo ""

# ─── Sketch Lab ───────────────────────────────────────────────────────────
echo "1) localhost/sketchlab:v0.5.0"
if [ -f "${PROJECT_DIR}/containers/sketchlab/Containerfile" ]; then
    echo "   Building from containers/sketchlab/ ..."
    podman build -t localhost/sketchlab:v0.5.0 \
        -f "${PROJECT_DIR}/containers/sketchlab/Containerfile" \
        "${PROJECT_DIR}/containers/sketchlab/"
    echo "   Done."
else
    echo "   WARNING: Containerfile not found at containers/sketchlab/ — skipping."
    echo "   To build from the upstream source, run:"
    echo "     git clone git@github.com:dark5un/sketchlab.app.git"
    echo "     cd sketchlab.app"
    echo "     podman build -t localhost/sketchlab:v0.5.0 ."
fi
echo ""

# ─── ComfyUI ──────────────────────────────────────────────────────────────
echo "2) localhost/comfyui:v0.30.2-cu130"
if [ -f "${PROJECT_DIR}/containers/comfyui/Containerfile" ]; then
    echo "   Building from containers/comfyui/ ..."
    podman build -t localhost/comfyui:v0.30.2-cu130 \
        -f "${PROJECT_DIR}/containers/comfyui/Containerfile" \
        "${PROJECT_DIR}/containers/comfyui/"
    echo "   Done."
else
    echo "   NOTE: No containers/comfyui/ found — using pre-built image."
    echo "   If you need a custom ComfyUI image, place a Containerfile at"
    echo "   containers/comfyui/Containerfile and build it yourself,"
    echo "   or use yanwk/comfyui-wrapper:cuda13 from Docker Hub."
fi
echo ""

echo "=== Build complete ==="
echo "Custom images ready. You can now run:"
echo "  systemctl --user daemon-reload"
echo "  systemctl --user enable --now sketchlab.service"