#!/usr/bin/env bash
# download-gguf-series.sh — Download a LIST of GGUF models in series via
# hf-download.sh, then refresh per-model presets once at the end.
#
# The model list is external data so this script never goes stale: edit the
# list, not the script. One entry per line:
#
#     repo|filename-or-filter
#
#   repo                 HuggingFace repo, e.g. unsloth/Qwen3.8-27B-GGUF
#   filename-or-filter   exact .gguf filename (preferred — globs are
#                        case-sensitive, e.g. Q4_K_M != q4_k_m) or a glob/substr
#
# Blank lines and lines starting with # are ignored.
#
# Usage:
#   download-gguf-series.sh [list-file]
#   # default list: ~/.config/llama.cpp/gguf-download-list.txt
#   # see scripts/gguf-download-list.example for the format

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HF_DL="${SCRIPT_DIR}/hf-download.sh"
REFRESH="${SCRIPT_DIR}/refresh-presets.py"

LIST="${1:-${HOME}/.config/llama.cpp/gguf-download-list.txt}"

if [ ! -f "$LIST" ]; then
    echo "No list file: $LIST"
    echo "Copy scripts/gguf-download-list.example there and edit it, or pass a path:"
    echo "  download-gguf-series.sh /path/to/list.txt"
    exit 1
fi

command -v hf >/dev/null 2>&1 || { echo "Error: 'hf' CLI not found."; exit 1; }

# Parse entries (skip blanks/comments)
ENTRIES=()
while IFS= read -r line; do
    line="${line%$'\r'}"                       # strip CR (Windows-edited lists)
    case "$line" in
        ''|\#*) continue ;;
    esac
    ENTRIES+=("$line")
done < "$LIST"

if [ ${#ENTRIES[@]} -eq 0 ]; then
    echo "List $LIST has no entries."
    exit 1
fi

echo "=== download-gguf-series ==="
echo "  List:     $LIST"
echo "  Entries:  ${#ENTRIES[@]}"
echo ""

fail=0
i=0
for entry in "${ENTRIES[@]}"; do
    i=$((i+1))
    repo="${entry%%|*}"
    filter="${entry#*|}"
    if [ "$repo" = "$entry" ]; then
        echo "──────────────── $i/${#ENTRIES[@]} : MALFORMED (no '|'): $entry"
        fail=1
        continue
    fi
    echo "──────────────── $i/${#ENTRIES[@]} : $repo  [$filter]"
    # Defer preset refresh + restart until all downloads finish
    if ! HF_DOWNLOAD_NO_REFRESH=1 "$HF_DL" "$repo" "$filter"; then
        echo "  ✗ failed: $repo"
        fail=1
    fi
    echo ""
done

# ─── Refresh presets + restart once ───────────────────────────────────────
echo "════════ refreshing presets for all models ════════"
if [ -f "$REFRESH" ]; then
    python3 "$REFRESH" --write || { echo "! refresh-presets.py failed"; fail=1; }
else
    echo "! refresh-presets.py not found next to this script"
    fail=1
fi

if systemctl --user is-active llama-cpp-main.service &>/dev/null; then
    echo ""
    echo "Restarting llama-cpp-main.service..."
    systemctl --user restart llama-cpp-main.service || true
fi

echo ""
if [ "$fail" -ne 0 ]; then
    echo "Finished WITH ERRORS (see above)."
    exit 1
fi
echo "Done. Verify with: curl http://127.0.0.1:11435/v1/models"