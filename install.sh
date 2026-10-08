#!/usr/bin/env bash
# install.sh — install the ai-lab-quadlets stack on THIS host (Arch, RTX 5090 +
# RTX 4070 Ti, rootless podman). Idempotent: re-running changes nothing that
# is already in place.
#
#   ./install.sh [--no-images] [--rebuild] [--with-deepseek-harness] [--with-hermes]
#
#   --no-images              skip pulling/building images (configs + units only)
#   --rebuild                rebuild the locally built images
#   --with-deepseek-harness  also deploy the opt-in DeepSeek Harness (dsh)
#   --with-hermes            also deploy the opt-in Hermes gateway container
#                            (this host runs Hermes natively; normally not wanted)
#
# Nothing is enabled at boot and nothing is started, stopped or restarted
# (except obsolete legacy units, which are stopped before removal). Start
# services on demand: `scripts/ai-lab start <name>` or the AI Lab bar widget.
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REG="$ROOT/services.json"
CONF="${HOME}/.config/containers/config"
QUADLET_DIR="${HOME}/.config/containers/systemd"
DATA="${HOME}/.local/share"

NO_IMAGES=0 REBUILD=0 WITH_DSH=0 WITH_HERMES=0
for arg in "$@"; do
    case "$arg" in
        --no-images) NO_IMAGES=1 ;;
        --rebuild) REBUILD=1 ;;
        --with-deepseek-harness) WITH_DSH=1 ;;
        --with-hermes) WITH_HERMES=1 ;;
        -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $arg (see --help)" >&2; exit 2 ;;
    esac
done

say() { printf '\n== %s\n' "$*"; }

# ─── 1. Prerequisites ────────────────────────────────────────────────────────
say "1/6 prerequisites"
for cmd in podman nvidia-smi python3 openssl systemctl hostnamectl; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "  ! missing command: $cmd" >&2; exit 1; }
done
[ "$(podman info --format '{{.Host.Security.Rootless}}')" = true ] || { echo "  ! podman is not rootless" >&2; exit 1; }
GPUS="$(nvidia-smi --query-gpu=name --format=csv,noheader)"
for card in "RTX 5090" "RTX 4070 Ti"; do
    grep -q "$card" <<<"$GPUS" || { echo "  ! nvidia-smi does not list the $card; this installer is for the 5090 + 4070 Ti host" >&2; exit 1; }
done
echo "  ✓ podman $(podman --version | awk '{print $3}') rootless; GPUs: $(paste -sd, <<<"$GPUS")"
command -v hf >/dev/null 2>&1 && echo "  ✓ hf (Hugging Face CLI)" \
    || echo "  ~ hf not installed (needed by hf-download): sudo pacman -S python-huggingface-hub"

# ─── 2. Configs ──────────────────────────────────────────────────────────────
say "2/6 configs in $CONF"
umask 077
mkdir -p "$CONF"; chmod 700 "$CONF"

# Legacy layout: llama.cpp/ + llama.cpp-research/ (generator output). Keep
# only the API key, under the new name.
if [ -f "$CONF/llama.cpp/keys.txt" ] && [ ! -f "$CONF/llama-cpp/keys.txt" ]; then
    mkdir -p "$CONF/llama-cpp"; chmod 700 "$CONF/llama-cpp"
    mv "$CONF/llama.cpp/keys.txt" "$CONF/llama-cpp/keys.txt"
    chmod 600 "$CONF/llama-cpp/keys.txt"
    echo "  moved llama.cpp/keys.txt -> llama-cpp/keys.txt"
fi
if [ -f "$CONF/llama-cpp/keys.txt" ]; then
    for legacy in llama.cpp llama.cpp-research; do
        [ -d "$CONF/$legacy" ] || continue
        rm -rf "${CONF:?}/$legacy"
        echo "  removed legacy $legacy/ (old generated service.env/presets.ini, no models)"
    done
fi
# Build markers whose image is gone, and template copies an older installer
# deployed (the repo's .example files are the only templates).
[ -f "$CONF/.comfyui-cu130-built" ] && { rm -f "$CONF/.comfyui-cu130-built"; echo "  removed stale .comfyui-cu130-built"; }
if [ -f "$CONF/.deepseek-harness-built" ] && ! podman image exists localhost/deepseek-harness:0.1.2-rc.1; then
    rm -f "$CONF/.deepseek-harness-built"; echo "  removed stale .deepseek-harness-built"
fi
while IFS= read -r -d '' ex; do
    rm -f "$ex"; echo "  removed deployed template ${ex#"$CONF"/}"
done < <(find "$CONF" -name '*.example' -print0)

AI_LAB_CONFIG_DIR="$CONF" "$ROOT/scripts/generate-secrets.sh" \
    $([ "$WITH_HERMES" = 1 ] && echo --with-hermes)

# Non-secret configs: copy each repo template once; the deployed copy is
# the user's to edit afterwards.
copy_examples() {  # copy_examples <svc>
    local svc="$1" ex dst
    mkdir -p "$CONF/$svc"; chmod 700 "$CONF/$svc"
    for ex in "$ROOT/config/$svc"/*.example; do
        [ -f "$ex" ] || continue
        dst="$CONF/$svc/$(basename "${ex%.example}")"
        if [ ! -f "$dst" ]; then
            install -m 600 "$ex" "$dst"; echo "  created $svc/$(basename "$dst")"
        fi
        chmod 600 "$dst"
    done
}
for svc in llama-cpp-5090 llama-cpp-4070ti llama-cpp-both sketchlab; do copy_examples "$svc"; done

# Strata: image (if missing) + its three units + its service.env with the key.
say "3/6 strata (scripts/install-strata.sh)"
AI_LAB_NO_RELOAD=1 "$ROOT/scripts/install-strata.sh" | sed 's/^/  /'

# Managed lines, rewritten on every run from the live keys (values never printed).
set_kv() {  # set_kv <file> <KEY> <value>
    python3 - "$@" <<'EOF'
import os, sys
path, key, val = sys.argv[1:4]
lines = open(path).read().splitlines() if os.path.exists(path) else []
out, done = [], False
for ln in lines:
    if ln.startswith(key + "="):
        if not done:
            out.append(f"{key}={val}"); done = True
        continue
    out.append(ln)
if not done:
    out.append(f"{key}={val}")
tmp = path + ".tmp"
with open(tmp, "w") as f:
    f.write("\n".join(out) + "\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
EOF
}
env_get() { sed -n "s/^$2=//p" "$1" | tail -1; }
STRATA_KEY="$(env_get "$CONF/strata/service.env" API_KEY)"
LLAMA_KEY="$(grep -v '^#' "$CONF/llama-cpp/keys.txt" | grep -m1 . || true)"
[ -n "$STRATA_KEY" ] && [ -n "$LLAMA_KEY" ] || { echo "  ! strata or llama.cpp key missing" >&2; exit 1; }
HOST_LOCAL="$(hostnamectl --static).local"

OW="$CONF/open-webui/service.env"
set_kv "$OW" WEBUI_URL "http://${HOST_LOCAL}:3100"
set_kv "$OW" CORS_ALLOW_ORIGIN "http://${HOST_LOCAL}:3100"
set_kv "$OW" OPENAI_API_BASE_URLS "http://systemd-strata:8080/v1;http://systemd-llama-cpp-5090:8080/v1;http://systemd-llama-cpp-4070ti:8080/v1;http://systemd-llama-cpp-both:8080/v1"
set_kv "$OW" OPENAI_API_KEYS "${STRATA_KEY};${LLAMA_KEY};${LLAMA_KEY};${LLAMA_KEY}"
echo "  open-webui: 4 backends (strata, llama-cpp-5090/4070ti/both), URL http://${HOST_LOCAL}:3100"
set_kv "$CONF/sketchlab/service.env" STRATA_API_KEY "$STRATA_KEY"
echo "  sketchlab: /v1 proxy key = strata key"
if [ "$WITH_DSH" = 1 ]; then
    DSH="$CONF/deepseek-harness/service.env"
    mkdir -p "$(dirname "$DSH")"; chmod 700 "$(dirname "$DSH")"
    [ -f "$DSH" ] || printf '# DeepSeek Harness. DSH_PORT: dsh binds 127.0.0.1:<port> (Network=host).\nDSH_PORT=3105\n' > "$DSH"
    set_kv "$DSH" STRATA_API_KEY "$STRATA_KEY"
    set_kv "$DSH" LLAMA_CPP_API_KEY "$LLAMA_KEY"
    DSH_SETTINGS="$DATA/deepseek-harness/settings.yaml"
    if [ ! -f "$DSH_SETTINGS" ]; then
        mkdir -p "$(dirname "$DSH_SETTINGS")"
        install -m 600 "$ROOT/config/deepseek-harness/settings.yaml.example" "$DSH_SETTINGS"
        echo "  created $DSH_SETTINGS"
    fi
    echo "  deepseek-harness: strata + llama.cpp keys"
fi
umask 022

# ─── 4. Units ────────────────────────────────────────────────────────────────
say "4/6 units in $QUADLET_DIR"
UNITS=(ai llama-cpp-5090 llama-cpp-4070ti llama-cpp-both comfyui-5090 comfyui-4070ti rizzo open-webui sketchlab hyperframes)
[ "$WITH_DSH" = 1 ] && UNITS+=(deepseek-harness)
[ "$WITH_HERMES" = 1 ] && UNITS+=(hermes)
"$ROOT/scripts/render-units.sh" "${UNITS[@]}"

LEGACY=(llama-cpp-main llama-cpp-research llama-cpp-cpu comfyui comfyui-cpu strata caddy)
[ "$WITH_DSH" = 1 ] || LEGACY+=(deepseek-harness)
[ "$WITH_HERMES" = 1 ] || LEGACY+=(hermes)
for f in "$QUADLET_DIR"/llama-cpp-extra-*.container; do
    [ -f "$f" ] && LEGACY+=("$(basename "$f" .container)")
done
for name in "${LEGACY[@]}"; do
    [ -f "$QUADLET_DIR/$name.container" ] || continue
    systemctl --user stop "$name.service" 2>/dev/null || true
    rm -f "$QUADLET_DIR/$name.container"
    echo "  removed legacy $name.container"
done
# podman 6 makes every quadlet wait for podman-user-wait-network-online, which
# times out on Arch: the stack is local-only, so mask it (uninstall unmasks).
systemctl --user mask podman-user-wait-network-online.service >/dev/null 2>&1 || true
systemctl --user reset-failed podman-user-wait-network-online.service >/dev/null 2>&1 || true
systemctl --user daemon-reload
echo "  ✓ daemon-reload (nothing enabled, nothing started)"

# ─── 5. Data dirs ────────────────────────────────────────────────────────────
say "5/6 data dirs"
mkdir -p "$DATA"/llama.cpp/cards/{5090,4070ti,both} "$DATA"/comfyui "$DATA"/sketchlab "$DATA"/rizzo
[ "$WITH_HERMES" = 1 ] && mkdir -p "$DATA/hermes-service"
echo "  ✓ ~/.local/share/{llama.cpp/cards/{5090,4070ti,both},comfyui,sketchlab,rizzo}"
mkdir -p "${HOME}/.local/bin"
for tool in ai-lab:scripts/ai-lab hf-download:scripts/hf-download.sh; do
    ln -sfn "$ROOT/${tool#*:}" "${HOME}/.local/bin/${tool%%:*}"
done
echo "  ✓ ~/.local/bin/ai-lab, ~/.local/bin/hf-download -> repo scripts"

# ─── 6. Images ───────────────────────────────────────────────────────────────
say "6/6 images"
if [ "$NO_IMAGES" = 1 ]; then
    echo "  skipped (--no-images)"
else
    IMAGES=(open-webui llama-cpp comfyui rizzo sketchlab hyperframes)
    [ "$WITH_DSH" = 1 ] && IMAGES+=(deepseek-harness)
    [ "$WITH_HERMES" = 1 ] && IMAGES+=(hermes)
    "$ROOT/scripts/build-images.sh" $([ "$REBUILD" = 1 ] && echo --rebuild) "${IMAGES[@]}" \
        || echo "  ! some images are missing (see above); their services will not start until built"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
say "deployed (none started, none at boot)"
python3 - "$REG" "$QUADLET_DIR" <<'EOF'
import json, os, sys
reg, qdir = json.load(open(sys.argv[1])), sys.argv[2]
print(f"  {'SERVICE':<18} {'PORT':<16} {'CARD':<7} AUTH")
for s in reg["services"]:
    if os.path.exists(os.path.join(qdir, s["unit"].replace(".service", ".container"))):
        print(f"  {s['name']:<18} {s['bind'] + ':' + str(s['host_port']):<16} {s.get('gpu', '-'):<7} {s['auth']}")
EOF
cat <<EOF

Start/stop on demand (GPU rules applied by scripts/gpu-arbiter.py):
  ai-lab start <name>   |  ai-lab strata 5090|4070ti|both|off  |  ai-lab status
  or the AI Lab bar widget (plugin/ailab).
Models for llama.cpp: hf-download <repo> <quant> --card 5090|4070ti|both
EOF
