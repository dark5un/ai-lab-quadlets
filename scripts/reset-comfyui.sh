#!/usr/bin/env bash
# reset-comfyui.sh — wipe ComfyUI's configuration/runtime state (settings, DB,
# manager state, logs, temp, caches under user/.cache) and keep models/,
# input/, output/ and custom_nodes/.
#
#   scripts/reset-comfyui.sh [--dry-run] [--backup]
#     --dry-run  report what would be removed, change nothing
#     --backup   tar ~/.local/share/comfyui/user first
#
# ComfyUI is stopped through `ai-lab stop comfyui` and started again the same
# way if it was running. user/ is recreated empty: the SQLite DB (Alembic,
# migrated on first start) fails to open when user/ is missing (ComfyUI #11233).
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
AI_LAB="$ROOT/scripts/ai-lab"
DIR="${HOME}/.local/share/comfyui"
DRY=0 BACKUP=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        --backup) BACKUP=1 ;;
        *) printf 'Unknown option: %s (supported: --dry-run --backup)\n' "$arg" >&2; exit 2 ;;
    esac
done
[ -d "$DIR" ] || { echo "No ComfyUI data at $DIR"; exit 0; }

was_running=0
if systemctl --user is-active --quiet comfyui-5090.service \
    || systemctl --user is-active --quiet comfyui-4070ti.service; then
    was_running=1
fi
if [ "$DRY" = 0 ] && [ "$was_running" = 1 ]; then
    "$AI_LAB" stop comfyui
fi

if [ "$BACKUP" = 1 ] && [ -d "$DIR/user" ]; then
    tar_file="$DIR/user-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    if [ "$DRY" = 1 ]; then
        echo "  [dry-run] would back up user/ -> ${tar_file##*/}"
    else
        tar -czf "$tar_file" -C "$DIR" user && echo "  backed up user/ -> ${tar_file##*/}"
    fi
fi

for target in user temp comfyui.log; do
    [ -e "$DIR/$target" ] || { echo "  ~ $target not present"; continue; }
    if [ "$DRY" = 1 ]; then
        echo "  [dry-run] would remove $target"
    else
        rm -rf "${DIR:?}/$target" && echo "  removed $target"
    fi
done

if [ "$DRY" = 0 ]; then
    mkdir -p "$DIR/user"
    echo "  recreated user/"
    [ "$was_running" = 1 ] && "$AI_LAB" start comfyui
fi
echo "ComfyUI reset $([ "$DRY" = 1 ] && echo '(dry run) ')done; models/input/output/custom_nodes kept."
