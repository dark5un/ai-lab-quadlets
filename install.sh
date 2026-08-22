#!/usr/bin/env bash
# install.sh — One-command installer for AI Lab Quadlets
#
# Detects GPUs, generates configs, copies files, and enables services.
# Idempotent — safe to re-run on an already-installed system.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/dark5un/ai-lab-quadlets/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/dark5un/ai-lab-quadlets/main/install.sh | bash -s -- --force-rebuild
#   # or from a local checkout:
#   ./install.sh [--force-rebuild]

set -uo pipefail

FORCE_REBUILD=0
# Parse CLI args: ./install.sh --force-rebuild  OR  curl ... | bash -s -- --force-rebuild
for arg in "$@"; do
    case "$arg" in
        --force-rebuild) FORCE_REBUILD=1 ;;
        *) echo "Unknown option: $arg (supported: --force-rebuild)"; exit 1 ;;
    esac
done

# ─── Config ───────────────────────────────────────────────────────────────
REPO_URL="https://github.com/dark5un/ai-lab-quadlets"
QUADLET_DIR="${HOME}/.config/containers/systemd"
CONFIG_DIR="${HOME}/.config/containers/config"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd 2>/dev/null || pwd)"
# PROJECT_DIR intentionally omitted — $0 is unreliable under piped stdin (curl | bash).
# The clone-fallback logic below handles that case.

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
SYSTEMD_AVAILABLE=false
if [ "$(systemctl --user is-system-running 2>/dev/null || true)" = "offline" ]; then
    echo "  ~ user systemd not available (running in container?)"
    echo "  ~ quadlets will be installed but not enabled."
else
    SYSTEMD_AVAILABLE=true
    echo "  ✓ systemd --user available"
fi

# nvidia-container-toolkit (optional — for GPU support)
NVIDIA_AVAILABLE=false
if command -v nvidia-smi &>/dev/null; then
    NVIDIA_AVAILABLE=true
    echo "  ✓ NVIDIA GPU(s) detected"
    if ! podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null | grep -q true; then
        echo "  ~ nvidia-container-toolkit may need rootful installation"
    fi
else
    echo "  ~ No NVIDIA GPUs detected — will use CPU-only llama.cpp"
fi

# Container images — check which we already have
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
# If the script is inside a git checkout (local file), use that. Otherwise clone.
if [ -d "${SCRIPT_DIR}/quadlets" ] && [ -f "${SCRIPT_DIR}/quadlets/ai.network" ]; then
    SOURCE_DIR="$SCRIPT_DIR"
    echo "[2/6] Using local checkout at $SOURCE_DIR"
elif [ -d "${SCRIPT_DIR}/../quadlets" ] && [ -f "${SCRIPT_DIR}/../quadlets/ai.network" ]; then
    # Fallback: script is inside a subdirectory of the checkout
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
LLAMA_CPP_IMAGE_TAG="server"  # default — overridden below for iGPU/Vulkan path
if [ "$NVIDIA_AVAILABLE" = true ]; then
    bash "${SOURCE_DIR}/scripts/detect-gpus.sh" \
        --output-dir "${SOURCE_DIR}/quadlets" \
        --config-dir "${SOURCE_DIR}/config" || true
else
    # CPU fallback — detect iGPU for Vulkan acceleration
    if ls /dev/dri/renderD* &>/dev/null 2>&1; then
        LLAMA_CPP_IMAGE_TAG="server-vulkan"
        echo "  → Detected iGPU — using Vulkan-accelerated llama.cpp (server-vulkan)"
        sed "s|^Image=.*:server$|Image=ghcr.io/ggml-org/llama.cpp:server-vulkan|" \
            "${SOURCE_DIR}/quadlets/llama-cpp-cpu.container" \
            > "${SOURCE_DIR}/quadlets/llama-cpp-main.container"
        sed -i '/^\[Service\]/i\# Expose host GPU for Vulkan/iGPU acceleration' \
            "${SOURCE_DIR}/quadlets/llama-cpp-main.container"
        sed -i '/^\[Service\]/i\AddDevice=/dev/dri:/dev/dri' \
            "${SOURCE_DIR}/quadlets/llama-cpp-main.container"
    else
        cp "${SOURCE_DIR}/quadlets/llama-cpp-cpu.container" "${SOURCE_DIR}/quadlets/llama-cpp-main.container" 2>/dev/null || true
        echo "  → Using CPU-only llama.cpp (no iGPU detected)"
    fi

    # Generate CPU service.env with concrete values (not template placeholders)
    mkdir -p "${SOURCE_DIR}/config/llama.cpp"
    if [ ! -f "${SOURCE_DIR}/config/llama.cpp/service.env" ]; then
        if [ "$LLAMA_CPP_IMAGE_TAG" = "server-vulkan" ]; then
            echo "  → Enabling iGPU offload (LLAMA_ARG_N_GPU_LAYERS=99)"
            cat > "${SOURCE_DIR}/config/llama.cpp/service.env" <<'VULKENV'
# llama.cpp service.env — CPU + iGPU (Vulkan)
# Generated by install.sh (CPU fallback with iGPU detected)
LLAMA_ARG_N_GPU_LAYERS=99
LLAMA_ARG_MODELS_DIR=/models
LLAMA_ARG_MODELS_MAX=1
LLAMA_ARG_MODELS_AUTOLOAD=true
LLAMA_ARG_MODELS_PRESET=/etc/llama-cpp/presets.ini
LLAMA_ARG_LOAD_MODE=none
LLAMA_ARG_HOST=0.0.0.0
LLAMA_ARG_PORT=8080
LLAMA_ARG_CTX_SIZE=32768
LLAMA_ARG_N_PARALLEL=1
LLAMA_ARG_N_PREDICT=-1
LLAMA_ARG_UBATCH=128
LLAMA_ARG_BATCH=512
LLAMA_ARG_FIT=off
LLAMA_ARG_JINJA=true
LLAMA_ARG_ENDPOINT_METRICS=true
LLAMA_ARG_ENDPOINT_SLOTS=true
LLAMA_ARG_TIMEOUT=3600
LLAMA_ARG_SSE_PING_INTERVAL=30
VULKENV
        else
            cat > "${SOURCE_DIR}/config/llama.cpp/service.env" <<'CPUENV'
# llama.cpp service.env — CPU-only
# Generated by install.sh (CPU fallback)
LLAMA_ARG_MODELS_DIR=/models
LLAMA_ARG_MODELS_MAX=1
LLAMA_ARG_MODELS_AUTOLOAD=true
LLAMA_ARG_MODELS_PRESET=/etc/llama-cpp/presets.ini
LLAMA_ARG_LOAD_MODE=none
LLAMA_ARG_HOST=0.0.0.0
LLAMA_ARG_PORT=8080
LLAMA_ARG_CTX_SIZE=32768
LLAMA_ARG_N_PARALLEL=1
LLAMA_ARG_N_PREDICT=-1
LLAMA_ARG_UBATCH=128
LLAMA_ARG_BATCH=512
LLAMA_ARG_FIT=off
LLAMA_ARG_JINJA=true
LLAMA_ARG_ENDPOINT_METRICS=true
LLAMA_ARG_ENDPOINT_SLOTS=true
LLAMA_ARG_TIMEOUT=3600
LLAMA_ARG_SSE_PING_INTERVAL=30
CPUENV
        fi
    fi
    if [ ! -f "${SOURCE_DIR}/config/llama.cpp/presets.ini" ]; then
        cat > "${SOURCE_DIR}/config/llama.cpp/presets.ini" <<'CPUPRE'
# llama.cpp per-model presets — CPU
# Generated by install.sh (CPU fallback)

version = 1

[*]
ctx-size = 8192
n-predict = -1
n-gpu-layers = 0
fit = off
jinja = on
load-mode = mmap

CPUPRE
    fi
fi
echo ""

# ─── Generate secrets ─────────────────────────────────────────────────────
echo "[4/6] Generating secrets..."
bash "${SOURCE_DIR}/scripts/generate-secrets.sh" || true
echo ""

# ─── Copy files to runtime locations ──────────────────────────────────────
echo "[5/6] Deploying to system directories..."

# Quadlets
mkdir -p "$QUADLET_DIR"
echo "  → Copying quadlets to $QUADLET_DIR/"
cp "${SOURCE_DIR}/quadlets/ai.network" "$QUADLET_DIR/"
for quadlet in "${SOURCE_DIR}/quadlets/"*.container; do
    fname=$(basename "$quadlet")
    # Skip CPU fallback if main was generated
    if [[ "$fname" == llama-cpp-cpu.container ]]; then
        if [ -f "${SOURCE_DIR}/quadlets/llama-cpp-main.container" ]; then
            continue
        fi
    fi
    # Skip comfyui-cpu variant — handled separately below
    if [[ "$fname" == comfyui-cpu.container ]]; then
        continue
    fi
    cp "$quadlet" "$QUADLET_DIR/"
    echo "  ✓ $fname"
done

# ComfyUI: deploy the right variant based on hardware
if [ "$NVIDIA_AVAILABLE" = true ]; then
    echo "  ✓ comfyui.container (CUDA — AddDevice configured)"
else
    cp "${SOURCE_DIR}/quadlets/comfyui-cpu.container" "$QUADLET_DIR/comfyui.container"
    echo "  ✓ comfyui.container (CPU — no GPU detected)"
fi

# Configs (don't overwrite existing service.env or presets.ini on reinstall)
# Determine the REAL avahi-published .local name (handles hostname conflicts,
# e.g. framework → framework-13.local). Fall back to hostname -s + .local.
HOSTNAME_SHORT=$(hostname -s 2>/dev/null || echo "localhost")

# 1. Try reading the name avahi actually publishes
AVAHI_NAME=""
if command -v avahi-resolve &>/dev/null; then
    AVAHI_NAME=$(systemctl status avahi-daemon 2>/dev/null | grep -o 'running \[[^]]*\]' | sed 's/running \[\(.*\)\]/\1/' | head -1)
fi
# 2. Fall back to hostname -s .local
if [ -z "$AVAHI_NAME" ]; then
    AVAHI_NAME="${HOSTNAME_SHORT}.local"
fi
LOCAL_HOSTNAME="$AVAHI_NAME"
echo "  → Using published hostname: ${LOCAL_HOSTNAME}"

mkdir -p "$CONFIG_DIR"
echo "  → Deploying configs to $CONFIG_DIR/ (existing .env and presets preserved)..."
for config_item in "${SOURCE_DIR}/config/"*; do
    item_name=$(basename "$config_item")
    target="${CONFIG_DIR}/${item_name}"
    if [ -d "$config_item" ]; then
        # Directory — merge contents without overwriting
        mkdir -p "$target"
        for file in "$config_item"/*; do
            fname=$(basename "$file")
            # Caddyfile.example becomes Caddyfile with hostname substitution
            # ALWAYS overwrites — avahi-published hostname can change between
            # reboots (e.g. framework-13.local → framework.local), and Caddy
            # needs the current one to bind correctly.
            if [[ "$fname" == "Caddyfile.example" ]]; then
                sed "s/HOSTNAME\.local/${LOCAL_HOSTNAME}/g" "$file" > "${target}/Caddyfile" 2>/dev/null || cp "$file" "${target}/Caddyfile"
                echo "  ✓ caddy/Caddyfile (hostname substituted)"
            elif [[ "$fname" == *.example ]]; then
                # Always copy .example files (they're templates)
                cp "$file" "$target/" 2>/dev/null || true
            elif [ ! -f "${target}/${fname}" ]; then
                # Only copy non-example files if they don't exist yet
                # Substitute HOSTNAME.local with the real hostname
                sed "s/HOSTNAME\.local/${LOCAL_HOSTNAME}/g" "$file" > "${target}/${fname}" 2>/dev/null || cp "$file" "${target}/${fname}"
                echo "  ✓ ${item_name}/${fname} (hostname substituted)"
            fi
        done
    fi
done

# Runtime data directories
mkdir -p \
    "${HOME}/.local/share/sketchlab" \
    "${HOME}/.local/share/comfyui" \
    "${HOME}/.local/share/hermes-service" \
    "${HOME}/.local/share/deepseek-harness" \
    "${HOME}/.local/share/llama.cpp/models"
echo "  → Runtime data directories created (including models/)"

# Podman network (idempotent — safe to re-run)
echo "  → Ensuring podman network 'ai.network' exists..."
podman network exists ai.network 2>/dev/null || podman network create ai.network
echo ""

# ─── Container images ────────────────────────────────────────────────────
echo "  ~ Ensuring container images..."

# Caddy
podman pull docker.io/library/caddy:2-alpine 2>/dev/null && echo "  ✓ caddy"

# Open WebUI
podman pull ghcr.io/open-webui/open-webui:v0.11.0 2>/dev/null && echo "  ✓ open-webui"

# Hermes
podman pull docker.io/nousresearch/hermes-agent:latest 2>/dev/null && echo "  ✓ hermes"

# Sketch Lab — try GHCR first, fall back to local build
echo "  ~ Sketch Lab image..."
if podman image exists localhost/sketchlab:v0.5.0 2>/dev/null; then
    echo "  ✓ localhost/sketchlab:v0.5.0 (already exists)"
elif podman pull ghcr.io/dark5un/sketchlab:v0.5.0 2>/dev/null; then
    # Tag as localhost too so the quadlet can find it
    podman tag ghcr.io/dark5un/sketchlab:v0.5.0 localhost/sketchlab:v0.5.0 2>/dev/null || true
    echo "  ✓ ghcr.io/dark5un/sketchlab:v0.5.0"
elif [ -d "${HOME}/sketchlab.app" ]; then
    echo "  ~ Building from local sketchlab.app clone..."
    (cd "${HOME}/sketchlab.app" && podman build -t localhost/sketchlab:v0.5.0 .) && echo "  ✓ built sketchlab" || echo "  ! Build failed"
elif command -v git &>/dev/null; then
    echo "  ~ Building sketchlab from source..."
    TMP_CLONE=$(mktemp -d /tmp/sketchlab-XXXXX)
    git clone --depth=1 https://github.com/dark5un/sketchlab.app.git "$TMP_CLONE" 2>/dev/null && \
        (cd "$TMP_CLONE" && podman build -t localhost/sketchlab:v0.5.0 .) && \
        echo "  ✓ built sketchlab from source" || \
        echo "  ! Sketch Lab image not available — build manually: see README"
    rm -rf "$TMP_CLONE" 2>/dev/null || true
else
    echo "  ! Sketch Lab image not available — build manually: see README"
fi

# ─── ComfyUI image (CUDA or CPU based on hardware) ───────────────────────
# Rebuilds when FORCE_REBUILD=1, or when the Containerfile hash changed since
# the last build (marker file in the persistent config dir).
echo "  ~ ComfyUI image..."
if [ "$NVIDIA_AVAILABLE" = true ]; then
    # CUDA build — see containers/comfyui/Containerfile
    CF_HASH=$(sha256sum "${SOURCE_DIR}/containers/comfyui/Containerfile" 2>/dev/null | cut -d' ' -f1)
    if [ "${FORCE_REBUILD:-0}" = "1" ] || [ "$(cat "${CONFIG_DIR}/.comfyui-cu130-built" 2>/dev/null)" != "$CF_HASH" ]; then
        podman rm -f comfyui 2>/dev/null || true
        podman rmi -f localhost/comfyui:v0.30.2-cu130 2>/dev/null || true
    fi
    if podman image exists localhost/comfyui:v0.30.2-cu130 2>/dev/null; then
        echo "  ✓ localhost/comfyui:v0.30.2-cu130 (already exists)"
    elif [ -f "${SOURCE_DIR}/containers/comfyui/Containerfile" ]; then
        echo "  ~ Building CUDA ComfyUI image (this takes a while)..."
        (cd "${SOURCE_DIR}/containers/comfyui" && podman build -t localhost/comfyui:v0.30.2-cu130 -f Containerfile .) && \
            echo "$CF_HASH" > "${CONFIG_DIR}/.comfyui-cu130-built" && \
            echo "  ✓ built CUDA comfyui" || echo "  ! CUDA ComfyUI build failed — see containers/comfyui/Containerfile"
    else
        echo "  ! No comfyui Containerfile found"
    fi
else
    # CPU build — see containers/comfyui/Containerfile.cpu
    CF_HASH=$(sha256sum "${SOURCE_DIR}/containers/comfyui/Containerfile.cpu" 2>/dev/null | cut -d' ' -f1)
    if [ "${FORCE_REBUILD:-0}" = "1" ] || [ "$(cat "${CONFIG_DIR}/.comfyui-cpu-built" 2>/dev/null)" != "$CF_HASH" ]; then
        podman rm -f comfyui 2>/dev/null || true
        podman rmi -f localhost/comfyui-cpu:v0.30.2 2>/dev/null || true
    fi
    if podman image exists localhost/comfyui-cpu:v0.30.2 2>/dev/null; then
        echo "  ✓ localhost/comfyui-cpu:v0.30.2 (already exists)"
    elif [ -f "${SOURCE_DIR}/containers/comfyui/Containerfile.cpu" ]; then
        echo "  ~ Building CPU ComfyUI image (this takes a while)..."
        (cd "${SOURCE_DIR}/containers/comfyui" && podman build -t localhost/comfyui-cpu:v0.30.2 -f Containerfile.cpu .) && \
            echo "$CF_HASH" > "${CONFIG_DIR}/.comfyui-cpu-built" && \
            echo "  ✓ built CPU comfyui" || echo "  ! CPU ComfyUI build failed — see containers/comfyui/Containerfile.cpu"
    else
        echo "  ! No comfyui Containerfile.cpu found"
    fi
fi
echo ""

# ─── DeepSeek Harness image ────────────────────────────────────────────
# Rebuilds when --force-rebuild, or when the Containerfile hash changed.
echo "  ~ DeepSeek Harness image..."
DSH_HASH=$(sha256sum "${SOURCE_DIR}/containers/deepseek-harness/Containerfile" 2>/dev/null | cut -d' ' -f1)
if [ "$FORCE_REBUILD" = "1" ] || [ "$(cat "${CONFIG_DIR}/.deepseek-harness-built" 2>/dev/null)" != "$DSH_HASH" ]; then
    podman rm -f deepseek-harness 2>/dev/null || true
    podman rmi -f localhost/deepseek-harness:0.1.0-rc.6 2>/dev/null || true
fi
if podman image exists localhost/deepseek-harness:0.1.0-rc.6 2>/dev/null; then
    echo "  ✓ localhost/deepseek-harness:0.1.0-rc.6 (already exists)"
elif [ -f "${SOURCE_DIR}/containers/deepseek-harness/Containerfile" ]; then
    echo "  ~ Building DeepSeek Harness image (this takes a while)..."
    (cd "${SOURCE_DIR}/containers/deepseek-harness" && podman build -t localhost/deepseek-harness:0.1.0-rc.6 -f Containerfile .) && \
        echo "$DSH_HASH" > "${CONFIG_DIR}/.deepseek-harness-built" && \
        echo "  ✓ built deepseek-harness" || echo "  ! DeepSeek Harness build failed — see containers/deepseek-harness/Containerfile"
else
    echo "  ! No deepseek-harness Containerfile found"
fi
echo ""

# llama.cpp server (pulled automatically by systemd, but ensure it's available)
echo "  ~ Pulling llama.cpp ${LLAMA_CPP_IMAGE_TAG} image (background)..."
podman pull "ghcr.io/ggml-org/llama.cpp:${LLAMA_CPP_IMAGE_TAG}" 2>/dev/null &
echo ""

# ─── hf-download tool ────────────────────────────────────────────────────
echo "  ~ Deploying hf-download tool to ~/.local/bin/..."
mkdir -p "${HOME}/.local/bin"
cp "${SOURCE_DIR}/scripts/hf-download.sh" "${HOME}/.local/bin/hf-download" 2>/dev/null
chmod +x "${HOME}/.local/bin/hf-download" 2>/dev/null
echo "  ✓ ~/.local/bin/hf-download"

# Ensure the Hugging Face CLI (hf) is available (needed by hf-download).
if command -v hf &>/dev/null; then
    echo "  ✓ hf CLI (Hugging Face): $(hf --version 2>/dev/null | head -1)"
elif command -v brew &>/dev/null; then
    echo "  ~ Installing hf CLI via brew..."
    brew install hf 2>/dev/null && echo "  ✓ installed via brew" || \
        echo "  ! brew install failed — trying pip..."
    if ! command -v hf &>/dev/null && command -v pip3 &>/dev/null; then
        pip3 install --user --upgrade "huggingface_hub" 2>/dev/null && echo "  ✓ installed via pip" || \
            echo "  ! pip install failed"
    fi
elif command -v pip3 &>/dev/null; then
    echo "  ~ Installing hf CLI via pip..."
    pip3 install --user --upgrade "huggingface_hub" 2>/dev/null && echo "  ✓ installed via pip" || \
        echo "  ! pip install failed"
elif command -v curl &>/dev/null; then
    echo "  ~ Installing hf CLI via standalone installer..."
    curl -LsSf https://hf.co/cli/install.sh | bash 2>/dev/null && echo "  ✓ installed" || \
        echo "  ! standalone install failed"
fi

# Final check — warn clearly if no working CLI is available
if ! command -v hf &>/dev/null; then
    echo "  ! No working Hugging Face CLI (hf) found."
    echo "  ! hf-download needs it. Install one of:"
    echo "      brew install hf"
    echo "      pip install --user huggingface_hub"
    echo "      curl -LsSf https://hf.co/cli/install.sh | bash"
fi
echo ""

# ─── Enable and start services ────────────────────────────────────────────
echo "[6/6] Starting services..."

if [ "$SYSTEMD_AVAILABLE" = true ]; then
    systemctl --user daemon-reload

    # Helper: restart a service if its quadlet exists, tolerate failure
    restart_service() {
        local svc="$1"
        if [ -f "$QUADLET_DIR/${svc}.container" ]; then
            echo "  → ${svc}..."
            systemctl --user enable "${svc}.service" 2>/dev/null || true
            systemctl --user restart "${svc}.service" 2>/dev/null || \
                echo "  ! ${svc} failed to start"
        fi
    }

    # Restart in dependency order
    restart_service ai-network
    sleep 1
    restart_service llama-cpp-main
    restart_service open-webui
    restart_service caddy
    restart_service sketchlab
    restart_service deepseek-harness

    echo ""
    echo "============================================="
    echo "  Deployment Complete!                        "
    echo "============================================="
    echo ""
    echo "Running AI Lab services:"
    systemctl --user list-units --type=service --state=running --no-pager 2>/dev/null | grep -E '\b(ai-network|llama|caddy|open-webui|sketchlab|comfyui|hermes)' || echo "  (none running yet — some may still be pulling images)"
else
    echo "  ~ Systemd user services not available."
    echo "  ~ Quadlets are installed; start manually with:"
    echo "    podman network create ai.network"
    for q in "$QUADLET_DIR"/*.container; do
        name=$(basename "$q" .container)
        echo "    podman start $name"
    done
fi

echo ""
echo "Next steps:"
echo "  1. Download models with hf-download:"
echo "     hf-download unsloth/Qwen3.8-27B-GGUF Q4_K_M"
echo "  2. Edit presets in ~/.config/containers/config/llama.cpp/presets.ini"
echo "  3. Access services via Caddy (tls internal — avahi .local name):"
echo "     • Open WebUI:  https://${LOCAL_HOSTNAME}:3001"
echo "     • ComfyUI:     https://${LOCAL_HOSTNAME}:3002"
echo "     • Hermes:      https://${LOCAL_HOSTNAME}:3003"
echo "     • Sketch Lab:  https://${LOCAL_HOSTNAME}:3004"
echo "     • DSH:         https://${LOCAL_HOSTNAME}:3005"
echo "  4. See https://github.com/dark5un/sketchlab.app for the sketchlab skill"
echo "     that lets AI agents generate diagrams into Sketch Lab."