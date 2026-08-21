# AI Lab Quadlets — ujust recipes
#
# Usage:  just -f ai-lab.just install
#         just -f ai-lab.just uninstall
#
# For permanent ujust integration, see docs/ujust-integration.md

# ─── Project root (where this justfile lives) ─────────────────────────────
root := justfile_directory()

# ─── Global config ────────────────────────────────────────────────────────
quadlet_dir := home + "/.config/containers/systemd"
config_dir := home + "/.config/containers/config"

# ─── Recipes ──────────────────────────────────────────────────────────────

# Install all AI Lab Quadlet services
# Detects GPUs, generates configs, builds images, copies files, enables services
install:
    #!/usr/bin/env bash
    set -euo pipefail
    ROOT="{{root}}"
    QUADLET_DIR="{{quadlet_dir}}"
    CONFIG_DIR="{{config_dir}}"

    echo "=== AI Lab Quadlets — Install ==="
    echo ""

    # 1. GPU detection
    echo "[1/5] Detecting GPUs..."
    bash "$ROOT/scripts/detect-gpus.sh" \
        --output-dir "$ROOT/quadlets" \
        --config-dir "$ROOT/config"

    # 2. Generate secrets (if .env doesn't exist yet)
    echo "[2/5] Generating secrets..."
    bash "$ROOT/scripts/generate-secrets.sh"

    # 3. Build custom images
    echo "[3/5] Building custom container images..."
    bash "$ROOT/scripts/build-images.sh"

    # 4. Copy files to runtime locations
    echo "[4/5] Deploying to runtime directories..."
    mkdir -p "$QUADLET_DIR" "$CONFIG_DIR"

    # Quadlets
    cp "$ROOT/quadlets/ai.network" "$QUADLET_DIR/"
    for q in "$ROOT/quadlets/"*.container; do
        fname=$(basename "$q")
        # Skip CPU fallback if main was generated
        if [[ "$fname" == llama-cpp-cpu.container ]] && [ -f "$ROOT/quadlets/llama-cpp-main.container" ]; then
            continue
        fi
        cp "$q" "$QUADLET_DIR/"
        echo "  ✓ $fname"
    done

    # Configs
    cp -r "$ROOT/config/"* "$CONFIG_DIR/"
    echo "  → Configs deployed"

    # Runtime data directories
    mkdir -p "$HOME/.local/share/sketchlab" "$HOME/.local/share/comfyui" "$HOME/.local/share/hermes-service"

    # 5. Enable and start services
    echo "[5/5] Starting services..."
    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user enable --now ai-network.service 2>/dev/null || echo "  ! ai-network (may need rootful podman)"
    systemctl --user enable --now llama-cpp-main.service 2>/dev/null || echo "  ! llama-cpp-main (GPU check)"
    for svc in caddy open-webui sketchlab comfyui hermes; do
        if [ -f "$QUADLET_DIR/${svc}.container" ]; then
            systemctl --user enable --now "${svc}.service" 2>/dev/null || echo "  ! ${svc}"
        fi
    done

    echo ""
    echo "=== Install complete ==="
    echo "Place GGUF models in ~/.local/share/llama.cpp/models/"
    echo "Edit presets in ~/.config/containers/config/llama.cpp/presets.ini"


# Uninstall all AI Lab Quadlet services
# Stops services, removes quadlets, preserves data volumes
uninstall:
    #!/usr/bin/env bash
    set -euo pipefail
    ROOT="{{root}}"
    QUADLET_DIR="{{quadlet_dir}}"

    echo "=== AI Lab Quadlets — Uninstall ==="
    echo ""

    if [ ! -d "$QUADLET_DIR" ]; then
        echo "No AI Lab quadlets found — nothing to uninstall."
        exit 0
    fi

    # 1. Stop and disable services (built-in order respects dependencies)
    echo "[1/3] Stopping services..."
    for svc in hermes comfyui sketchlab caddy open-webui llama-cpp-research llama-cpp-main ai-network; do
        if systemctl --user is-enabled "${svc}.service" &>/dev/null; then
            systemctl --user disable --now "${svc}.service" 2>/dev/null || true
            echo "  ✓ disabled $svc"
        fi
    done

    # 2. Remove quadlet files
    echo "[2/3] Removing quadlet files..."
    for f in ai.network caddy.container comfyui.container hermes.container \
             llama-cpp-main.container llama-cpp-research.container \
             llama-cpp-extra-*.container open-webui.container sketchlab.container; do
        if [ -f "$QUADLET_DIR/$f" ]; then
            rm -f "$QUADLET_DIR/$f"
            echo "  ✓ removed $f"
        fi
    done

    systemctl --user daemon-reload 2>/dev/null || true

    # 3. Ask about config and data
    echo "[3/3] Cleaning up..."
    echo ""
    echo "Config and data directories preserved:"
    echo "  ~/.config/containers/config/  (edit configs)"
    echo "  ~/.local/share/llama.cpp/     (models — keep for reinstall)"
    echo "  ~/.local/share/comfyui/       (workflows, models)"
    echo "  ~/.local/share/sketchlab/     (diagrams)"
    echo "  ~/.local/share/hermes-service/"
    echo ""
    echo "To remove configs: rm -rf ~/.config/containers/config/"
    echo "To remove models:  rm -rf ~/.local/share/llama.cpp/models/"
    echo ""

    echo "=== Uninstall complete ==="


# Show status of installed services
status:
    #!/usr/bin/env bash
    echo "=== AI Lab Quadlets — Status ==="
    echo ""
    for unit in ai-network caddy open-webui llama-cpp-main llama-cpp-research \
                comfyui sketchlab hermes; do
        if systemctl --user is-active "${unit}.service" &>/dev/null; then
            echo "  ✓ $unit    (active)"
        elif systemctl --user is-enabled "${unit}.service" &>/dev/null; then
            echo "  - $unit    (enabled, not running)"
        else
            echo "  ✗ $unit    (not installed)"
        fi
    done