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
RESET_COMFYUI=0
DRY_RUN=0
BACKUP=0
SKIP_RESOLVE_CHECK=0
SKIP_HERMES=0
# Parse CLI args: ./install.sh [--force-rebuild] [--reset-comfyui] [--dry-run] [--backup]
#   --force-rebuild   rebuild container images
#   --reset-comfyui   wipe ComfyUI configuration/runtime (settings, DB, manager state, logs, temp, caches); keeps models/input/output/custom_nodes
#   --dry-run         with --reset-comfyui, only report what would be removed
#   --backup          with --reset-comfyui, tar ~/.local/share/comfyui/user before deleting
#   --skip-resolve-check  skip the up-front .local resolution gate
#   --skip-hermes     do not start the containerized Hermes gateway (e.g. when
#                     you already run Hermes natively on the host)
for arg in "$@"; do
    case "$arg" in
        --force-rebuild) FORCE_REBUILD=1 ;;
        --reset-comfyui) RESET_COMFYUI=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --backup) BACKUP=1 ;;
        --skip-resolve-check) SKIP_RESOLVE_CHECK=1 ;;
        --skip-hermes) SKIP_HERMES=1 ;;
        *) echo "Unknown option: $arg (supported: --force-rebuild --reset-comfyui --dry-run --backup --skip-resolve-check --skip-hermes)"; exit 1 ;;
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
for img in docker.io/library/caddy:2-alpine ghcr.io/open-webui/open-webui:v0.11.3 docker.io/nousresearch/hermes-agent:latest; do
    if podman image exists "$img" 2>/dev/null; then
        echo "  ✓ $img"
    else
        echo "  ~ Will pull: $img"
    fi
done

echo ""

# ─── ComfyUI config reset (standalone: ./install.sh --reset-comfyui) ──────
# Wipes ComfyUI configuration/runtime (settings, DB, manager state, logs, temp,
# caches) while preserving models/input/output/custom_nodes. Caches live under
# user/.cache, so wiping user/ covers them. The user/ dir is recreated so the
# SQLite DB — managed by Alembic and auto-migrated on first start — can open
# cleanly (ComfyUI issue #11233: the DB fails to open when user/ is missing).
# --dry-run only reports what would be removed; --backup tars user/ first.
if [ "$RESET_COMFYUI" = 1 ]; then
    COMFYUI_DIR="${HOME}/.local/share/comfyui"
    echo "============================================="
    echo "  ComfyUI Config Reset                    "
    echo "============================================="
    echo ""

    # Stop comfyui so we don't wipe data it is writing to.
    if [ "$SYSTEMD_AVAILABLE" = true ]; then
        systemctl --user stop comfyui.service 2>/dev/null || true
        sleep 1
    else
        podman stop systemd-comfyui 2>/dev/null || true
    fi

    # Optional backup of user/ before deleting.
    if [ "$BACKUP" = 1 ]; then
        BACKUP_TAR="${COMFYUI_DIR}/user-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
        if [ "$DRY_RUN" = 1 ]; then
            echo "  ~ [dry-run] would back up user/ → ${BACKUP_TAR##*/}"
        elif tar -czf "$BACKUP_TAR" -C "$COMFYUI_DIR" user 2>/dev/null; then
            echo "  ✓ backed up user/ → ${BACKUP_TAR##*/}"
        else
            echo "  ! backup failed — continuing without it"
        fi
    fi

    # Wipe configuration/runtime. Keep models/input/output/custom_nodes.
    echo "  → Wiping (dry-run: ${DRY_RUN}); keeping models/input/output/custom_nodes..."
    for target in user temp comfyui.log; do
        if [ ! -e "${COMFYUI_DIR}/${target}" ]; then
            echo "  ~ ${target} not present — nothing to remove"
            continue
        fi
        if [ "$DRY_RUN" = 1 ]; then
            echo "  ~ [dry-run] would remove ${target}"
        else
            rm -rf "${COMFYUI_DIR}/${target}" && echo "  ✓ removed ${target}" \
                || echo "  ! failed to remove ${target}"
        fi
    done

    # Recreate user/ so the DB can open on next ComfyUI start.
    if [ "$DRY_RUN" != 1 ]; then
        mkdir -p "${COMFYUI_DIR}/user" && echo "  → recreated user/"
    fi

    # Bring comfyui back up on the clean data, if it was deployed.
    if [ "$DRY_RUN" != 1 ] && [ "$SYSTEMD_AVAILABLE" = true ] \
        && [ -f "${QUADLET_DIR}/comfyui.container" ]; then
        echo "  → Restarting comfyui service..."
        systemctl --user "restart" "comfyui.service" 2>/dev/null \
            && echo "  ✓ comfyui restarted" \
            || echo "  ! comfyui failed to restart"
    elif [ "$DRY_RUN" != 1 ] && [ "$SYSTEMD_AVAILABLE" != true ]; then
        podman start systemd-comfyui 2>/dev/null || echo "  ! could not start comfyui"
    fi

    echo ""
    if [ "$DRY_RUN" = 1 ]; then
        echo "  Dry-run complete — nothing was actually removed."
    else
        echo "  ComfyUI config reset complete."
    fi
    echo "============================================="
    echo ""
    exit 0
fi

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
        if [ "$LLAMA_CPP_IMAGE_TAG" = "server-vulkan" ]; then
            cat > "${SOURCE_DIR}/config/llama.cpp/presets.ini" <<'VULKPRE'
# llama.cpp per-model presets — CPU + iGPU (Vulkan)
# Generated by install.sh (CPU fallback with iGPU detected)

version = 1

[*]
ctx-size = 8192
n-predict = -1
n-gpu-layers = 99
fit = off
jinja = on
load-mode = mmap

VULKPRE
        else
            cat > "${SOURCE_DIR}/config/llama.cpp/presets.ini" <<'CPUPRE'
# llama.cpp per-model presets — CPU-only
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
fi
echo ""

# ─── Generate secrets ─────────────────────────────────────────────────────
echo "[4/6] Generating secrets..."
bash "${SOURCE_DIR}/scripts/generate-secrets.sh" || true
echo ""

# ─── Determine current .local hostname ────────────────────────────────────
# Used to substitute HOSTNAME.local in config files (Caddyfile, open-webui).
# The avahi-published name can change between reboots (e.g. framework-13.local
# vs framework.local), so any file containing HOSTNAME.local is always
# regenerated on every install run.
HOSTNAME_SHORT=$(hostname -s 2>/dev/null || echo "localhost")
AVAHI_NAME=""
if command -v avahi-resolve &>/dev/null; then
    AVAHI_NAME=$(systemctl status avahi-daemon 2>/dev/null | grep -o 'running \[[^]]*\]' | sed 's/running \[\(.*\)\]/\1/' | head -1)
fi
if [ -z "$AVAHI_NAME" ]; then
    AVAHI_NAME="${HOSTNAME_SHORT}.local"
fi
LOCAL_HOSTNAME="$AVAHI_NAME"
echo "  → Using published hostname: ${LOCAL_HOSTNAME}"

# ─── Resolve preflight ──────────────────────────────────────────────────
# The Caddy endpoints are keyed to ${LOCAL_HOSTNAME}. If that name doesn't
# resolve through the OS (getent — the path ping/curl/browsers use), the
# deployed stack is unreachable by name and any CA trust we install is moot.
# This cannot be fixed generically (it needs nss-mdns + an nsswitch edit, or
# systemd-resolved), so detect it and stop up front unless the user opts out.
if [ "$SKIP_RESOLVE_CHECK" = 1 ]; then
    echo "  ~ (--skip-resolve-check) skipping .local resolution verification"
elif getent hosts "$LOCAL_HOSTNAME" >/dev/null 2>&1; then
    echo "  ✓ ${LOCAL_HOSTNAME} resolves through the OS (getent)"
else
    echo ""
    echo "  !!! ${LOCAL_HOSTNAME} does NOT resolve through the OS (getent)."
    echo "  !!! avahi may be advertising it, but glibc/ping/curl/browsers won't see it."
    echo "  !!! All service URLs (https://${LOCAL_HOSTNAME}:3001-3005) will be unreachable."
    echo ""
    echo "  On Arch, fix by installing nss-mdns and adding it to nsswitch.conf:"
    echo "      sudo pacman -S extra/nss-mdns"
    echo "      sudo sed -i 's/^hosts:.*/hosts: mymachines resolve [!UNAVAIL=return] files myhostname mdns4_minimal dns/' /etc/nsswitch.conf"
    echo "      getent hosts ${LOCAL_HOSTNAME}   # verify"
    echo ""
    echo "  (or enable systemd-resolved's mDNS instead — but that conflicts with avahi)"
    echo ""
    echo "  Aborting. Re-run with --skip-resolve-check to install anyway."
    exit 1
fi
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

# Config files — always regenerate files that contain HOSTNAME.local
# (avahi name can change between reboots). Preserve other existing files.
mkdir -p "$CONFIG_DIR"
echo "  → Deploying configs to $CONFIG_DIR/ ..."
for config_item in "${SOURCE_DIR}/config/"*; do
    item_name=$(basename "$config_item")
    target="${CONFIG_DIR}/${item_name}"
    if [ -d "$config_item" ]; then
        mkdir -p "$target"
        for file in "$config_item"/*; do
            fname=$(basename "$file")

            # If the source contains HOSTNAME.local, always regenerate the
            # destination with the current hostname (avahi name can change).
            if grep -q 'HOSTNAME\.local' "$file" 2>/dev/null; then
                target_file="${target}/${fname%.example}"
                sed "s/HOSTNAME\.local/${LOCAL_HOSTNAME}/g" "$file" > "$target_file" 2>/dev/null
                echo "  ✓ ${item_name}/${target_file##*/} (hostname substituted)"
            # Example files: always copy as-is (templates for new installs).
            elif [[ "$fname" == *.example ]]; then
                cp "$file" "$target/" 2>/dev/null || true
            # Other files: only copy if they don't exist yet (preserve manual edits).
            elif [ ! -f "${target}/${fname}" ]; then
                cp "$file" "${target}/${fname}" 2>/dev/null || true
                echo "  ✓ ${item_name}/${fname}"
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

# DeepSeek Harness env — upstream ships no service.env, but the quadlet's
# EnvironmentFile requires one or the container fails with exit 125
# ("no such file or directory"). Create a working default if missing.
DSH_ENV="${CONFIG_DIR}/deepseek-harness/service.env"
if [ ! -f "$DSH_ENV" ]; then
    mkdir -p "$(dirname "$DSH_ENV")"
    cat > "$DSH_ENV" <<EOF
# DeepSeek Harness (dsh) service.env — generated by install.sh.
# Upstream supplies no default; without this file the dsh quadlet exits 125.
DSH_PORT=3080
DSH_INTERNAL_PORT=3081
DSH_TRUSTED_HOSTS=${LOCAL_HOSTNAME}:3005
DSH_ALLOW_REMOTE_CONFIGURATION=true
EOF
    echo "  ✓ created ${DSH_ENV} (DSH_TRUSTED_HOSTS=${LOCAL_HOSTNAME}:3005)"
fi

# Podman network (idempotent — safe to re-run)
echo "  → Ensuring podman network 'ai.network' exists..."
podman network exists ai.network 2>/dev/null || podman network create ai.network
echo ""

# ─── Container images ────────────────────────────────────────────────────
echo "  ~ Ensuring container images..."

# Caddy
podman pull docker.io/library/caddy:2-alpine 2>/dev/null && echo "  ✓ caddy"

# Open WebUI
podman pull ghcr.io/open-webui/open-webui:v0.11.3 2>/dev/null && echo "  ✓ open-webui"

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
        podman rmi -f localhost/comfyui:v0.34.0-cu130 2>/dev/null || true
    fi
    if podman image exists localhost/comfyui:v0.34.0-cu130 2>/dev/null; then
        echo "  ✓ localhost/comfyui:v0.34.0-cu130 (already exists)"
    elif [ -f "${SOURCE_DIR}/containers/comfyui/Containerfile" ]; then
        echo "  ~ Building CUDA ComfyUI image (this takes a while)..."
        (cd "${SOURCE_DIR}/containers/comfyui" && podman build -t localhost/comfyui:v0.34.0-cu130 -f Containerfile .) && \
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
        podman rmi -f localhost/comfyui-cpu:v0.34.0 2>/dev/null || true
    fi
    if podman image exists localhost/comfyui-cpu:v0.34.0 2>/dev/null; then
        echo "  ✓ localhost/comfyui-cpu:v0.34.0 (already exists)"
    elif [ -f "${SOURCE_DIR}/containers/comfyui/Containerfile.cpu" ]; then
        echo "  ~ Building CPU ComfyUI image (this takes a while)..."
        (cd "${SOURCE_DIR}/containers/comfyui" && podman build -t localhost/comfyui-cpu:v0.34.0 -f Containerfile.cpu .) && \
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
    podman rmi -f localhost/deepseek-harness:0.1.2-rc.1 2>/dev/null || true
fi
if podman image exists localhost/deepseek-harness:0.1.2-rc.1 2>/dev/null; then
    echo "  ✓ localhost/deepseek-harness:0.1.2-rc.1 (already exists)"
elif [ -f "${SOURCE_DIR}/containers/deepseek-harness/Containerfile" ]; then
    echo "  ~ Building DeepSeek Harness image (this takes a while)..."
    (cd "${SOURCE_DIR}/containers/deepseek-harness" && podman build -t localhost/deepseek-harness:0.1.2-rc.1 -f Containerfile .) && \
        echo "$DSH_HASH" > "${CONFIG_DIR}/.deepseek-harness-built" && \
        echo "  ✓ built deepseek-harness" || echo "  ! DeepSeek Harness build failed — see containers/deepseek-harness/Containerfile"
else
    echo "  ! No deepseek-harness Containerfile found"
fi
echo ""

# ─── HyperFrames image (built from the local repo checkout) ───────────────
# The server role (gcp-cloud-run) reads PORT (default 8080) and is bun-native.
# Build context must be the monorepo ROOT so the @hyperframes/* workspaces are
# available. Falls back to GHCR if the local checkout is missing.
echo "  ~ HyperFrames image..."
HYPERFRAMES_REPO="${HYPERFRAMES_REPO:-/var/home/px/.distrobox/homes/hermes/repos/github.com/hyperframes}"
if podman image exists localhost/hyperframes:latest 2>/dev/null; then
    echo "  ✓ localhost/hyperframes:latest (already exists)"
elif podman pull ghcr.io/dark5un/hyperframes:latest 2>/dev/null; then
    podman tag ghcr.io/dark5un/hyperframes:latest localhost/hyperframes:latest 2>/dev/null || true
    echo "  ✓ pulled hyperframes from GHCR"
elif [ -d "${HYPERFRAMES_REPO}/packages/gcp-cloud-run/Dockerfile" ]; then
    echo "  ~ Building HyperFrames image (repo checkout: ${HYPERFRAMES_REPO})..."
    (cd "${HYPERFRAMES_REPO}" && podman build -t localhost/hyperframes:latest -f packages/gcp-cloud-run/Dockerfile .) && \
        echo "  ✓ built hyperframes" || echo "  ! HyperFrames build failed — see packages/gcp-cloud-run/Dockerfile"
else
    echo "  ! HyperFrames repo checkout not found — build manually: see quadlets/hyperframes.container"
fi
echo ""
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
    echo "  ~ Installing hf CLI..."
    curl -LsSf https://hf.co/cli/install.sh | bash 2>/dev/null && echo "  ✓ installed" || \
        echo "  ! brew install failed — try: brew install huggingface/tap/huggingface-cli"
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

# ─── TLS certificates (mkcert preferred, Caddy internal CA fallback) ────
TLS_METHOD="caddy-ca"
CERTS_DIR="${CONFIG_DIR}/caddy/certs"
mkdir -p "$CERTS_DIR"   # bind-mounted into caddy even in CA fallback mode
MKCERT_PRESENT=false
if command -v mkcert >/dev/null 2>&1; then
    MKCERT_PRESENT=true
fi
if [ "$MKCERT_PRESENT" = false ]; then
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        if [ "${ID:-}" = "arch" ] || [ "${ID_LIKE:-}" = "arch" ]; then
            echo "  ~ mkcert not found — installing via pacman..."
            if sudo -n true 2>/dev/null; then
                sudo pacman -S --noconfirm --needed mkcert && MKCERT_PRESENT=true \
                    || echo "  ! pacman install of mkcert failed"
            else
                echo "  ~ sudo needs a password — cannot auto-install mkcert"
            fi
        fi
    fi
fi

if [ "$MKCERT_PRESENT" = true ]; then
    echo "  ~ Using mkcert for locally-trusted TLS"
    CERT_FILE="${CERTS_DIR}/${LOCAL_HOSTNAME}.pem"
    KEY_FILE="${CERTS_DIR}/${LOCAL_HOSTNAME}-key.pem"

    if command -v update-ca-trust >/dev/null 2>&1 || command -v trust >/dev/null 2>&1; then
        if ! mkcert -install >/dev/null 2>&1; then
            echo "  ~ CA not added to system store (needs root?) — certs still generated."
            echo "    Run 'sudo mkcert -install' once to trust them system-wide."
        fi
    fi

    mkcert -cert-file "$CERT_FILE" -key-file "$KEY_FILE" \
        "${LOCAL_HOSTNAME}" localhost 127.0.0.1 ::1 >/dev/null 2>&1

    if [ -s "$CERT_FILE" ] && [ -s "$KEY_FILE" ]; then
        CAFILE="${CONFIG_DIR}/caddy/Caddyfile"
        if [ -f "$CAFILE" ]; then
            sed -i '/skip_install_trust/d' "$CAFILE"
            sed -i "s|\ttls internal$|\ttls /etc/caddy/certs/${LOCAL_HOSTNAME}.pem /etc/caddy/certs/${LOCAL_HOSTNAME}-key.pem|" "$CAFILE"
            echo "  ✓ Caddyfile configured for mkcert (${CERT_FILE})"
        fi
        TLS_METHOD="mkcert"
    else
        echo "  ! mkcert cert generation failed — falling back to Caddy internal CA"
    fi
else
    echo "  ~ mkcert not available — falling back to Caddy's internal CA"
    CAFILE="${CONFIG_DIR}/caddy/Caddyfile"
    if [ -f "$CAFILE" ] && grep -q '/etc/caddy/certs/' "$CAFILE"; then
        sed -i 's|tls /etc/caddy/certs/.*-key\.pem|tls internal|' "$CAFILE"
        echo "  ✓ Caddyfile reset to tls internal (no mkcert)"
    fi
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
    restart_service comfyui
    restart_service caddy
    restart_service sketchlab
    restart_service deepseek-harness
    if [ "$SKIP_HERMES" = 1 ]; then
        echo "  ~ (--skip-hermes) not starting containerized hermes.service"
    else
        restart_service hermes
    fi
    restart_service hyperframes

    echo ""
    echo "============================================="
    echo "  Deployment Complete!                        "
    echo "============================================="
    echo ""
    echo "Running AI Lab services:"
    systemctl --user list-units --type=service --state=running --no-pager 2>/dev/null | grep -E '\b(ai-network|llama|caddy|open-webui|sketchlab|comfyui|hermes|hyperframes)' || echo "  (none running yet — some may still be pulling images)"
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
# ─── Trust Caddy's local CA (fallback when mkcert unavailable) ─────────
# Only reached when TLS_METHOD != mkcert. Every endpoint is then served by
# Caddy with `tls internal` (self-signed local CA); unless that CA root is
# added to the OS trust store, browsers flag every URL as untrusted.
if [ "${TLS_METHOD:-}" != "mkcert" ]; then
    if [ "$SYSTEMD_AVAILABLE" = true ]; then
        echo "  ~ Trusting Caddy local CA for ${LOCAL_HOSTNAME}..."
        TMP_CA="$(mktemp /tmp/caddy-local-root-XXXXXX.crt)"
        if podman cp systemd-caddy:/data/caddy/pki/authorities/local/root.crt "$TMP_CA" 2>/dev/null && [ -s "$TMP_CA" ]; then
            if command -v update-ca-trust >/dev/null 2>&1; then
                if sudo -n true 2>/dev/null; then
                    sudo cp "$TMP_CA" /etc/ca-certificates/trust-source/anchors/caddy-local-root.crt
                    sudo update-ca-trust
                    echo "  ✓ Caddy CA trusted system-wide. Restart browsers to pick it up."
                else
                    echo "  ! Caddy CA not installed automatically (sudo needs a password)."
                    echo "    Run manually:"
                    echo "      sudo cp \"$TMP_CA\" /etc/ca-certificates/trust-source/anchors/caddy-local-root.crt"
                    echo "      sudo update-ca-trust"
                fi
            else
                echo "  ! update-ca-trust not found — trust Caddy CA in each client instead."
            fi
        else
            echo "  ~ Caddy CA not generated yet (created on first request)."
            echo "    After the first page load, trust it with:"
            echo "      podman cp systemd-caddy:/data/caddy/pki/authorities/local/root.crt /tmp/caddy-ca.crt"
            echo "      sudo cp /tmp/caddy-ca.crt /etc/ca-certificates/trust-source/anchors/caddy-local-root.crt"
            echo "      sudo update-ca-trust"
        fi
        rm -f "$TMP_CA"
    fi
fi
echo ""
echo "Next steps:"
echo "  1. Download models with hf-download:"
echo "     hf-download unsloth/Qwen3.8-27B-GGUF Q4_K_M"
echo "  2. Edit presets in ~/.config/containers/config/llama.cpp/presets.ini"
echo "  3. Access services via Caddy (${TLS_METHOD:-caddy-ca} TLS — avahi .local name):"
echo "     • Open WebUI:  https://${LOCAL_HOSTNAME}:3001"
echo "     • ComfyUI:     https://${LOCAL_HOSTNAME}:3002"
echo "     • Hermes:      https://${LOCAL_HOSTNAME}:3003"
echo "     • Sketch Lab:  https://${LOCAL_HOSTNAME}:3004"
echo "     • DSH:         https://${LOCAL_HOSTNAME}:3005"
echo "  4. See https://github.com/dark5un/sketchlab.app for the sketchlab skill"
echo "     that lets AI agents generate diagrams into Sketch Lab."