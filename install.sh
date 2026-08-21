#!/usr/bin/env bash
# install.sh — One-command installer for AI Lab Quadlets
#
# Detects GPUs, generates configs, copies files, and enables services.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/dark5un/ai-lab-quadlets/main/install.sh | bash
#   # or from a local checkout:
#   ./install.sh

set -euo pipefail

# ─── Config ───────────────────────────────────────────────────────────────
REPO_URL="https://github.com/dark5un/ai-lab-quadlets"
QUADLET_DIR="${HOME}/.config/containers/systemd"
CONFIG_DIR="${HOME}/.config/containers/config"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================="
echo "  AI Lab Quadlets — Reproducible Deployment  "
echo "============================================="
echo ""

# ─── Check prerequisites ──────────────────────────────────────────────────
echo "[1/6] Checking prerequisites..."

# Podman
if ! command -v podman &>/dev/null; then
    echo "ERROR: podman not found."
    echo "Install it on Bluefin: rpm-ostree install podman"
    echo "Or use the toolbox/distrobox version."
    exit 1
fi
echo "  ✓ podman: $(podman --version)"

# Systemd user services
if [ "$(systemctl --user is-system-running 2>/dev/null || true)" = "offline" ]; then
    echo "  ~ user systemd not available (running in container?)"
    echo "  ~ quadlets will be installed but not enabled."
    SYSTEMD_AVAILABLE=false
else
    SYSTEMD_AVAILABLE=true
    echo "  ✓ systemd --user available"
fi

# nvidia-container-toolkit (optional — for GPU support)
if command -v nvidia-smi &>/dev/null; then
    echo "  ✓ NVIDIA GPU(s) detected"
    if ! podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null | grep -q true; then
        echo "  ~ nvidia-container-toolkit may need rootful installation"
    fi
else
    echo "  ~ No NVIDIA GPUs detected — will use CPU-only llama.cpp"
fi

# Container images
echo "  ~ Checking required container images..."
for img in docker.io/library/caddy:2-alpine ghcr.io/open-webui/open-webui:v0.11.0 docker.io/nousresearch/hermes-agent:latest; do
    if podman image exists "$img" 2>/dev/null; then
        echo "  ✓ $img"
    else
        echo "  ~ Will pull: $img"
    fi
done

echo ""

# ─── Determine source directory ───────────────────────────────────────────
# If the script is inside a git checkout, use that. Otherwise clone.
if [ -d "${PROJECT_DIR}/.git" ] && [ -f "${PROJECT_DIR}/quadlets/ai.network" ]; then
    SOURCE_DIR="$PROJECT_DIR"
    echo "[2/6] Using local checkout at $SOURCE_DIR"
elif [ -d "${SCRIPT_DIR}/../quadlets" ]; then
    SOURCE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    echo "[2/6] Using local checkout at $SOURCE_DIR"
else
    SOURCE_DIR=$(mktemp -d /tmp/ai-lab-quadlets-XXXXX)
    echo "[2/6] Cloning from $REPO_URL ..."
    if command -v git &>/dev/null; then
        git clone --depth=1 "$REPO_URL" "$SOURCE_DIR"
    else
        echo "ERROR: git not found — can't clone."
        echo "Install git: rpm-ostree install git"
        exit 1
    fi
fi
echo ""

# ─── GPU Detection ────────────────────────────────────────────────────────
echo "[3/6] Detecting GPUs and generating llama.cpp configs..."
if command -v nvidia-smi &>/dev/null; then
    bash "${SOURCE_DIR}/scripts/detect-gpus.sh" \
        --output-dir "${SOURCE_DIR}/quadlets" \
        --config-dir "${SOURCE_DIR}/config"
else
    # CPU fallback — just copy the CPU quadlet as the main one
    cp "${SOURCE_DIR}/quadlets/llama-cpp-cpu.container" "${SOURCE_DIR}/quadlets/llama-cpp-main.container"
    echo "  → Using CPU version (llama-cpp-cpu.container)"

    # Generate basic CPU env
    mkdir -p "${SOURCE_DIR}/config/llama.cpp"
    if [ ! -f "${SOURCE_DIR}/config/llama.cpp/service.env" ]; then
        cp "${SOURCE_DIR}/config/llama.cpp/service.env.example" "${SOURCE_DIR}/config/llama.cpp/service.env" 2>/dev/null || true
    fi
    if [ ! -f "${SOURCE_DIR}/config/llama.cpp/presets.ini" ]; then
        cp "${SOURCE_DIR}/config/llama.cpp/presets.ini.example" "${SOURCE_DIR}/config/llama.cpp/presets.ini" 2>/dev/null || true
    fi
fi
echo ""

# ─── Generate secrets ─────────────────────────────────────────────────────
echo "[4/6] Generating secrets..."
bash "${SOURCE_DIR}/scripts/generate-secrets.sh"
echo ""

# ─── Copy files to runtime locations ──────────────────────────────────────
echo "[5/6] Deploying to system directories..."

# Quadlets
mkdir -p "$QUADLET_DIR"
echo "  → Copying quadlets to $QUADLET_DIR/"
# Copy network first, then container files
cp "${SOURCE_DIR}/quadlets/ai.network" "$QUADLET_DIR/"
for quadlet in "${SOURCE_DIR}/quadlets/"*.container; do
    fname=$(basename "$quadlet")
    # Skip template files and CPU fallback (which was already handled)
    if [[ "$fname" == llama-cpp-cpu.container ]]; then
        # Only copy CPU version if no GPUs and main already copied
        if [ -f "${SOURCE_DIR}/quadlets/llama-cpp-main.container" ]; then
            continue
        fi
    fi
    cp "$quadlet" "$QUADLET_DIR/"
    echo "  ✓ $fname"
done

# Configs
mkdir -p "$CONFIG_DIR"
cp -r "${SOURCE_DIR}/config/"* "$CONFIG_DIR/"
echo "  → Configs deployed to $CONFIG_DIR/"

# Runtime data directories
mkdir -p \
    "${HOME}/.local/share/sketchlab" \
    "${HOME}/.local/share/comfyui" \
    "${HOME}/.local/share/hermes-service"
echo "  → Runtime data directories created"

# Container image for sketchlab
echo "  ~ Building sketchlab image..."
if [ -f "${SOURCE_DIR}/containers/sketchlab/Containerfile" ]; then
    # Check if the source files exist (may be a submodule or just the Dockerfile)
    if [ -f "${SOURCE_DIR}/containers/sketchlab/package.json" ]; then
        podman build -t localhost/sketchlab:v0.5.0 \
            -f "${SOURCE_DIR}/containers/sketchlab/Containerfile" \
            "${SOURCE_DIR}/containers/sketchlab/" 2>/dev/null || \
            echo "  ! Sketchlab build skipped (source files may not be in this checkout)"
    else
        echo "  ! Sketchlab source not in containers/sketchlab/"
        echo "  ! Clone github.com/dark5un/sketchlab.app to build:"
        echo "    git clone https://github.com/dark5un/sketchlab.app.git"
        echo "    cd sketchlab.app && podman build -t localhost/sketchlab:v0.5.0 ."
    fi
fi
echo ""

# ─── Enable and start services ────────────────────────────────────────────
echo "[6/6] Starting services..."

if [ "$SYSTEMD_AVAILABLE" = true ]; then
    systemctl --user daemon-reload

    # Enable services in dependency order
    echo "  → Enabling ai-network (podman network)..."
    systemctl --user enable --now ai-network.service 2>/dev/null || \
        echo "  ! Could not enable ai-network.service"

    echo "  → Enabling llama-cpp-main..."
    systemctl --user enable --now llama-cpp-main.service 2>/dev/null || \
        echo "  ! Could not enable llama-cpp-main.service (GPU may not be available?)"

    # Optional services
    for svc in open-webui caddy sketchlab; do
        if [ -f "$QUADLET_DIR/${svc}.container" ]; then
            echo "  → Enabling ${svc}..."
            systemctl --user enable --now "${svc}.service" 2>/dev/null || \
                echo "  ! Could not enable ${svc}.service"
        fi
    done

    echo ""
    echo "============================================="
    echo "  Deployment Complete!                        "
    echo "============================================="
    echo ""
    echo "Running services:"
    systemctl --user list-units --type=service --state=running | grep -E '\b(ai-network|llama|caddy|open-webui|sketchlab|comfyui|hermes)' || true
else
    echo "  ~ Systemd user services not available."
    echo "  ~ Quadlets are installed; start manually with:"
    echo "    podman network create ai.network"
    for q in "$QUADLET_DIR"/*.container; do
        name=$(basename "$q" .container)
        echo "    podman-compose --file $q up -d $name"
    done
fi

echo ""
echo "Next steps:"
echo "  1. Place GGUF model files in ~/.local/share/llama.cpp/models/"
echo "  2. Edit presets in ~/.config/containers/config/llama.cpp/presets.ini"
echo "  3. Access services via Caddy:"
echo "     • Open WebUI:  https://dark5un.local:3001"
echo "     • ComfyUI:     https://dark5un.local:3002"
echo "     • Hermes:      https://dark5un.local:3003"
echo "     • Sketch Lab:  https://dark5un.local:3004"
echo "  4. See https://github.com/dark5un/sketchlab.app for the sketchlab skill"
echo "     that lets AI agents generate diagrams into Sketch Lab."