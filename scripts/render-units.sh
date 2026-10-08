#!/usr/bin/env bash
# render-units.sh — render quadlets/<name>.container.in into the user quadlet
# dir, filling the GPU UUID placeholders from nvidia-smi (cards matched by
# name, never by index), then copy plain quadlets/<name>.container files.
#
#   scripts/render-units.sh NAME...      e.g. strata-5090 llama-cpp-4070ti sketchlab
#
# Placeholders: __GPU_5090_UUID__, __GPU_4070TI_UUID__, __CPUS_MAIN__,
# __CPUS_CODER__. Does not daemon-reload,
# start or enable anything; the caller reloads once at the end.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUADLET_DIR="${QUADLET_DIR:-${HOME}/.config/containers/systemd}"

[ $# -gt 0 ] || { echo "usage: render-units.sh NAME..." >&2; exit 2; }

gpu_uuid() {  # gpu_uuid <name regex>
    nvidia-smi --query-gpu=name,uuid --format=csv,noheader | awk -F, -v pat="$1" '
        $1 ~ pat { u=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", u); print u; exit }'
}
UUID_5090="$(gpu_uuid 'RTX 5090')"
UUID_4070TI="$(gpu_uuid 'RTX 4070 Ti')"
# CPU pinning for the strata duo: strata-coder gets the last 8 logical CPUs
# (E-cores on this Core Ultra), the 5090 variants everything before them.
NCPU="$(nproc --all)"
CPUS_MAIN="0-$((NCPU - 9))"
CPUS_CODER="$((NCPU - 8))-$((NCPU - 1))"

mkdir -p "$QUADLET_DIR"
for name in "$@"; do
    if [ -f "$ROOT/quadlets/$name.container.in" ]; then
        src="$ROOT/quadlets/$name.container.in"
        if grep -q '__GPU_5090_UUID__' "$src" && [ -z "$UUID_5090" ]; then
            echo "render-units: $name needs the RTX 5090, which nvidia-smi does not list" >&2; exit 1
        fi
        if grep -q '__GPU_4070TI_UUID__' "$src" && [ -z "$UUID_4070TI" ]; then
            echo "render-units: $name needs the RTX 4070 Ti, which nvidia-smi does not list" >&2; exit 1
        fi
        tmp="$(mktemp "$QUADLET_DIR/.$name.XXXXXX")"
        sed -e "s/__GPU_5090_UUID__/${UUID_5090}/g" -e "s/__GPU_4070TI_UUID__/${UUID_4070TI}/g" \
            -e "s/__CPUS_MAIN__/${CPUS_MAIN}/g" -e "s/__CPUS_CODER__/${CPUS_CODER}/g" "$src" > "$tmp"
        install -m 0644 "$tmp" "$QUADLET_DIR/$name.container"
        rm -f "$tmp"
    elif [ -f "$ROOT/quadlets/$name.container" ]; then
        install -m 0644 "$ROOT/quadlets/$name.container" "$QUADLET_DIR/$name.container"
    elif [ -f "$ROOT/quadlets/$name.network" ]; then
        install -m 0644 "$ROOT/quadlets/$name.network" "$QUADLET_DIR/$name.network"
    else
        echo "render-units: no quadlets/$name.container(.in) or .network" >&2; exit 1
    fi
    echo "  ✓ $name"
done
