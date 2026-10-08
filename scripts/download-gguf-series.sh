#!/usr/bin/env bash
# download-gguf-series.sh — run hf-download for a LIST of models in series,
# then refresh presets and restart the affected llama.cpp servers once.
#
#   download-gguf-series.sh [list-file]
#   default list: ~/.config/llama.cpp/gguf-download-list.txt
#   format (see scripts/gguf-download-list.example), one entry per line:
#       repo|filename-or-filter|cards
#   cards = 5090 | 4070ti | both, or a comma list (e.g. 5090,4070ti).
#   Blank lines and lines starting with # are ignored.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
HF_DL="${SCRIPT_DIR}/hf-download.sh"
REFRESH="${SCRIPT_DIR}/refresh-presets.py"
LIST="${1:-${HOME}/.config/llama.cpp/gguf-download-list.txt}"

if [ ! -f "$LIST" ]; then
    echo "No list file: $LIST"
    echo "Copy scripts/gguf-download-list.example there and edit it, or pass a path."
    exit 1
fi

ENTRIES=()
while IFS= read -r line; do
    line="${line%$'\r'}"
    case "$line" in ''|\#*) continue ;; esac
    ENTRIES+=("$line")
done < "$LIST"
[ ${#ENTRIES[@]} -gt 0 ] || { echo "List $LIST has no entries."; exit 1; }

echo "=== download-gguf-series: ${#ENTRIES[@]} entries from $LIST"
fail=0 i=0
declare -A TOUCHED=()
for entry in "${ENTRIES[@]}"; do
    i=$((i+1))
    IFS='|' read -r repo filter cards extra <<<"$entry"
    if [ -z "${repo:-}" ] || [ -z "${filter:-}" ] || [ -z "${cards:-}" ] || [ -n "${extra:-}" ]; then
        echo "── $i/${#ENTRIES[@]}: MALFORMED (want repo|filter|cards): $entry"
        fail=1; continue
    fi
    echo "── $i/${#ENTRIES[@]}: $repo [$filter] -> $cards"
    if HF_DOWNLOAD_NO_REFRESH=1 "$HF_DL" "$repo" "$filter" --card "$cards"; then
        IFS=, read -r -a cl <<<"$cards"
        for c in "${cl[@]}"; do TOUCHED[$c]=1; done
    else
        echo "  ✗ failed: $repo"; fail=1
    fi
done

for card in "${!TOUCHED[@]}"; do
    presets="${HOME}/.config/containers/config/llama-cpp-${card}/presets.ini"
    if [ -f "$presets" ]; then
        python3 "$REFRESH" --card "$card" --write >/dev/null \
            && echo "presets refreshed: $presets" || { echo "! refresh-presets.py --card $card failed"; fail=1; }
    fi
    if systemctl --user is-active --quiet "llama-cpp-${card}.service"; then
        echo "restarting llama-cpp-${card}"
        systemctl --user restart "llama-cpp-${card}.service" || true
    fi
done

[ "$fail" = 0 ] || { echo "Finished WITH ERRORS (see above)."; exit 1; }
echo "Done. Models per card: hf-download --list"
