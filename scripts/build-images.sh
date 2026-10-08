#!/usr/bin/env bash
# build-images.sh — make sure every image the deployed quadlets use exists.
# Image names/tags come from services.json. Builds run one at a time.
#
#   scripts/build-images.sh [--rebuild] [NAME...]
#
# NAME: open-webui llama-cpp comfyui rizzo sketchlab hyperframes
#       deepseek-harness hermes        (default: the first six)
# Pulled images (open-webui, llama-cpp, hermes) are pulled only when missing;
# a pulled digest that differs from the registry's image_digest is reported.
# Built images are skipped when present unless --rebuild; comfyui also
# rebuilds when containers/comfyui/Containerfile changed since its last build.
# Strata has its own builder: scripts/install-strata.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
REG="$ROOT/services.json"
CONF="${HOME}/.config/containers/config"
SKETCHLAB_REPO="${SKETCHLAB_REPO:-${HOME}/workspace/github.com/dark5un/sketchlab.app}"
HYPERFRAMES_REPO="${HYPERFRAMES_REPO:-${HOME}/workspace/github.com/heygen-com/hyperframes}"
DEFAULT=(open-webui llama-cpp comfyui rizzo sketchlab hyperframes)

REBUILD=0 NAMES=()
for arg in "$@"; do
    case "$arg" in
        --rebuild) REBUILD=1 ;;
        -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "build-images: unknown option $arg" >&2; exit 2 ;;
        *) NAMES+=("$arg") ;;
    esac
done
[ ${#NAMES[@]} -gt 0 ] || NAMES=("${DEFAULT[@]}")

reg() {  # reg <service> <field>
    python3 - "$REG" "$1" "$2" <<'EOF'
import json, sys
for s in json.load(open(sys.argv[1]))["services"]:
    if s["name"] == sys.argv[2]:
        print(s.get(sys.argv[3], "")); break
EOF
}

fail=0
pull() {  # pull <service>
    local image digest have
    image="$(reg "$1" image)"; digest="$(reg "$1" image_digest)"
    if podman image exists "$image"; then
        echo "  ✓ $image (present)"
    else
        echo "  → pulling $image"
        podman pull "$image" >/dev/null || { echo "  ! pull failed: $image"; fail=1; return; }
        echo "  ✓ $image (pulled)"
    fi
    if [ -n "$digest" ]; then
        have="$(podman image inspect "$image" --format '{{.Digest}} {{join .RepoDigests " "}}')"
        # The registry pins the index (multi-arch) or the manifest digest; either matches.
        [[ " $have " == *"${digest##*@}"* ]] || echo "  ~ $image is ${have%% *}; services.json pins ${digest##*@} (update the registry or re-pull)"
    fi
}

build() {  # build <service> <context> [podman build args...]
    local svc="$1" ctx="$2"; shift 2
    local image; image="$(reg "$svc" image)"
    if [ "$REBUILD" = 0 ] && podman image exists "$image"; then
        echo "  ✓ $image (present)"; return 0
    fi
    [ -d "$ctx" ] || { echo "  ! $svc: build context $ctx not found"; fail=1; return 1; }
    echo "  → building $image from $ctx"
    if podman build -t "$image" "$@" "$ctx"; then
        echo "  ✓ $image (built)"
    else
        echo "  ! build failed: $image"; fail=1; return 1
    fi
}

for name in "${NAMES[@]}"; do
    echo "── $name"
    case "$name" in
        open-webui) pull open-webui ;;
        llama-cpp) pull llama-cpp-5090 ;;
        hermes) pull hermes ;;
        comfyui)
            cf="$ROOT/containers/comfyui/Containerfile"
            hash="$(sha256sum "$cf" | cut -d' ' -f1)"
            marker="$CONF/.comfyui-built"
            if [ "$(cat "$marker" 2>/dev/null)" != "$hash" ] && podman image exists "$(reg comfyui-5090 image)"; then
                echo "  ~ Containerfile changed since the last build: rebuilding"
                REBUILD_SAVE=$REBUILD; REBUILD=1
                build comfyui-5090 "$ROOT/containers/comfyui" -f "$cf" && echo "$hash" > "$marker"
                REBUILD=$REBUILD_SAVE
            else
                build comfyui-5090 "$ROOT/containers/comfyui" -f "$cf" && echo "$hash" > "$marker"
            fi ;;
        rizzo) build rizzo "$ROOT/containers/rizzo-flow" -f "$ROOT/containers/rizzo-flow/Containerfile" ;;
        sketchlab) build sketchlab "$SKETCHLAB_REPO" -f "$SKETCHLAB_REPO/Dockerfile" ;;
        hyperframes) build hyperframes "$HYPERFRAMES_REPO" -f "$HYPERFRAMES_REPO/packages/gcp-cloud-run/Dockerfile" ;;
        deepseek-harness) build deepseek-harness "$ROOT/containers/deepseek-harness" \
                              -f "$ROOT/containers/deepseek-harness/Containerfile" ;;
        *) echo "  ! unknown image '$name'"; fail=1 ;;
    esac
done
exit $fail
