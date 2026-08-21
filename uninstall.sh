#!/usr/bin/env bash
# uninstall.sh — Remove all AI Lab Quadlet services
#
# Stops and disables services, removes quadlet files, preserves data volumes.
# Does NOT require just/ujust. Works standalone.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/dark5un/ai-lab-quadlets/main/uninstall.sh | bash
#   # or from a local checkout:
#   ./uninstall.sh

set -uo pipefail

QUADLET_DIR="${HOME}/.config/containers/systemd"
CONFIG_DIR="${HOME}/.config/containers/config"

echo "============================================="
echo "  AI Lab Quadlets — Uninstall               "
echo "============================================="
echo ""

if [ ! -d "$QUADLET_DIR" ]; then
    echo "No AI Lab quadlets found — nothing to uninstall."
    exit 0
fi

# ─── Stop and disable services ────────────────────────────────────────────
echo "[1/3] Stopping and disabling services..."
SERVICES="hermes comfyui sketchlab caddy open-webui deepseek-harness llama-cpp-research llama-cpp-main ai-network"
for svc in $SERVICES; do
    if systemctl --user is-enabled "${svc}.service" &>/dev/null 2>/dev/null; then
        systemctl --user disable --now "${svc}.service" 2>/dev/null && echo "  ✓ disabled $svc" || echo "  ~ $svc (stopped with warnings)"
    elif systemctl --user is-active "${svc}.service" &>/dev/null 2>/dev/null; then
        systemctl --user stop "${svc}.service" 2>/dev/null && echo "  ✓ stopped $svc"
    fi
done
echo ""

# ─── Remove quadlet files ─────────────────────────────────────────────────
echo "[2/3] Removing quadlet files..."
for f in ai.network caddy.container comfyui.container hermes.container \
         deepseek-harness.container \
         llama-cpp-main.container llama-cpp-research.container \
         llama-cpp-extra-*.container open-webui.container sketchlab.container; do
    # shellcheck disable=SC2086
    for file in "$QUADLET_DIR"/$f; do
        [ -f "$file" ] && rm -f "$file" && echo "  ✓ removed $(basename "$file")"
    done
done

systemctl --user daemon-reload 2>/dev/null || true

# Remove hf-download tool
if [ -f "${HOME}/.local/bin/hf-download" ]; then
    rm -f "${HOME}/.local/bin/hf-download"
    echo "  ✓ removed hf-download (tool)"
fi
echo ""

# ─── Report what's preserved ──────────────────────────────────────────────
echo "[3/3] Cleanup complete."
echo ""
echo "Preserved (no data deleted):"
echo "  • ~/.config/containers/config/           (settings, presets, secrets)"
echo "  • ~/.local/share/llama.cpp/models/       (GGUF model files)"
echo "  • ~/.local/share/llama.cpp/              (logs, config)"
echo "  • ~/.local/share/comfyui/                (workflows, custom nodes)"
echo "  • ~/.local/share/sketchlab/              (diagrams)"
echo "  • ~/.local/share/hermes-service/         (agent data)"
echo "  • ~/.local/share/deepseek-harness/      (dsh config, sessions)"
echo "  • Container volumes (podman volume ls)   (DB data, caddy certs)"
echo ""
echo "To also remove configs and data, run these manually:"
echo "  rm -rf ~/.config/containers/config/"
echo "  rm -rf ~/.local/share/llama.cpp"
echo "  rm -rf ~/.local/share/comfyui"
echo "  rm -rf ~/.local/share/sketchlab"
echo "  rm -rf ~/.local/share/hermes-service"
echo "  rm -rf ~/.local/share/deepseek-harness"
echo "  podman volume prune -f"
echo ""
echo "============================================="
echo "  Uninstall complete.                        "
echo "============================================="