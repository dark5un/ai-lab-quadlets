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
# Idempotent — safe to re-run. Detects GPUs, generates configs, ensures images, starts services.
install:
    #!/usr/bin/env bash
    set -uo pipefail
    ROOT="{{root}}"
    QUADLET_DIR="{{quadlet_dir}}"
    CONFIG_DIR="{{config_dir}}"

    echo "=== AI Lab Quadlets — Install ==="
    echo ""

    # 1. GPU detection
    echo "[1/5] Detecting GPUs..."
    bash "$ROOT/scripts/detect-gpus.sh" \
        --output-dir "$ROOT/quadlets" \
        --config-dir "$ROOT/config" || true

    # 2. Generate secrets (don't overwrite existing)
    echo "[2/5] Generating secrets..."
    bash "$ROOT/scripts/generate-secrets.sh" || true

    # 3. Ensure container images
    echo "[3/5] Ensuring container images..."
    podman pull docker.io/library/caddy:2-alpine 2>/dev/null && echo "  ✓ caddy"
    podman pull ghcr.io/open-webui/open-webui:v0.11.0 2>/dev/null && echo "  ✓ open-webui"

    # Sketch Lab — try GHCR then local build
    if podman image exists localhost/sketchlab:v0.5.0 2>/dev/null; then
        echo "  ✓ sketchlab (already exists)"
    elif podman pull ghcr.io/dark5un/sketchlab:v0.5.0 2>/dev/null; then
        podman tag ghcr.io/dark5un/sketchlab:v0.5.0 localhost/sketchlab:v0.5.0 2>/dev/null || true
        echo "  ✓ sketchlab (from GHCR)"
    elif [ -d "$HOME/sketchlab.app" ]; then
        echo "  ~ Building sketchlab from sources..."
        (cd "$HOME/sketchlab.app" && podman build -t localhost/sketchlab:v0.5.0 .) && echo "  ✓ sketchlab" || echo "  ! sketchlab build failed"
    else
        TMP_CLONE=$(mktemp -d /tmp/sketchlab-XXXXX)
        git clone --depth=1 https://github.com/dark5un/sketchlab.app.git "$TMP_CLONE" 2>/dev/null && \
            (cd "$TMP_CLONE" && podman build -t localhost/sketchlab:v0.5.0 .) && echo "  ✓ sketchlab (built)" || \
            echo "  ! sketchlab image unavailable"
        rm -rf "$TMP_CLONE" 2>/dev/null || true
    fi

    # 4. Deploy files to runtime locations
    echo "[4/5] Deploying to runtime directories..."
    mkdir -p "$QUADLET_DIR" "$CONFIG_DIR"

    # Quadlets
    cp "$ROOT/quadlets/ai.network" "$QUADLET_DIR/"
    for q in "$ROOT/quadlets/"*.container; do
        fname=$(basename "$q")
        if [[ "$fname" == llama-cpp-cpu.container ]] && [ -f "$ROOT/quadlets/llama-cpp-main.container" ]; then
            continue
        fi
        cp "$q" "$QUADLET_DIR/"
        echo "  ✓ $fname"
    done

    # Configs (preserve existing) — detect real avahi-published .local name
    HOSTNAME_SHORT=$(hostname -s 2>/dev/null || echo "localhost")
    AVAHI_NAME=""
    if command -v avahi-resolve &>/dev/null; then
        AVAHI_NAME=$(systemctl status avahi-daemon 2>/dev/null | grep -o 'running \[[^]]*\]' | sed 's/running \[\(.*\)\]/\1/' | head -1)
    fi
    [ -z "$AVAHI_NAME" ] && AVAHI_NAME="${HOSTNAME_SHORT}.local"
    LOCAL_HOSTNAME="$AVAHI_NAME"
    echo "  → Deploying configs (existing .env and presets preserved, hostname: ${LOCAL_HOSTNAME})..."
    for config_item in "$ROOT/config/"*; do
        item_name=$(basename "$config_item")
        target="$CONFIG_DIR/$item_name"
        if [ -d "$config_item" ]; then
            mkdir -p "$target"
            for file in "$config_item"/*; do
                fname=$(basename "$file")
                if [[ "$fname" == "Caddyfile.example" ]]; then
                    if [ ! -f "$target/Caddyfile" ]; then
                        sed "s/HOSTNAME\.local/${LOCAL_HOSTNAME}/g" "$file" > "$target/Caddyfile" 2>/dev/null || cp "$file" "$target/Caddyfile"
                    fi
                elif [[ "$fname" == *.example ]]; then
                    cp "$file" "$target/" 2>/dev/null || true
                elif [ ! -f "$target/$fname" ]; then
                    sed "s/HOSTNAME\.local/${LOCAL_HOSTNAME}/g" "$file" > "$target/$fname" 2>/dev/null || cp "$file" "$target/$fname"
                fi
            done
        fi
    done

    # Runtime data + models dir
    mkdir -p "$HOME/.local/share/sketchlab" "$HOME/.local/share/comfyui" \
             "$HOME/.local/share/hermes-service" "$HOME/.local/share/llama.cpp/models"

    # Podman network
    podman network exists ai.network 2>/dev/null || podman network create ai.network

    # 5. Restart services
    echo "[5/5] Starting services..."
    systemctl --user daemon-reload 2>/dev/null || true

    for svc in ai-network llama-cpp-main open-webui caddy sketchlab comfyui hermes; do
        if [ -f "$QUADLET_DIR/${svc}.container" ]; then
            echo "  → ${svc}..."
            systemctl --user enable "${svc}.service" 2>/dev/null || true
            systemctl --user restart "${svc}.service" 2>/dev/null || echo "  ! ${svc}"
        fi
    done


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