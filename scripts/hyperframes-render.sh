#!/usr/bin/env bash
# HyperFrames one-shot render via Podman
# Usage: ./hyperframes-render.sh /path/to/composition /path/to/output.mp4
#
# Builds the HyperFrames image on first run, then renders.
# Image is cached for subsequent renders.

set -euo pipefail

COMPOSITION_DIR="${1:?Usage: $0 <composition-dir> <output.mp4>}"
OUTPUT_FILE="${2:?Usage: $0 <composition-dir> <output.mp4>}"
IMAGE_NAME="localhost/hyperframes-render:latest"
REPO_DIR="$(cd "$(dirname "$0")" && cd ../repos/github.com/hyperframes && pwd)"

# Build image if it doesn't exist
if ! podman image exists "$IMAGE_NAME" 2>/dev/null; then
    echo "Building HyperFrames render image (first run only)..."
    podman build -f "$REPO_DIR/packages/cli/src/docker/Dockerfile.render" \
        -t "$IMAGE_NAME" "$REPO_DIR"
    echo "Image built."
fi

# Ensure output directory exists
mkdir -p "$(dirname "$OUTPUT_FILE")"
OUTPUT_DIR="$(dirname "$OUTPUT_FILE")"
OUTPUT_BASE="$(basename "$OUTPUT_FILE")"

# Run render
podman run --rm \
    -v "$COMPOSITION_DIR:/project:ro" \
    -v "$OUTPUT_DIR:/output:Z" \
    "$IMAGE_NAME" \
    --output "/output/$OUTPUT_BASE"

echo "Render complete: $OUTPUT_FILE"
