#!/usr/bin/env bash
# hf-download — fetch a GGUF into the Hugging Face cache (one copy) and make it
# available to one or more llama.cpp servers by HARDLINKING it into their
# per-card model dirs. A model on two cards costs disk once.
#
#   hf-download <repo> [quant-or-glob] --card 5090|4070ti|both[,...] [--name NAME]
#   hf-download --remove NAME --card 5090|4070ti|both[,...]
#   hf-download --list
#
# Examples:
#   hf-download unsloth/Qwen3.8-27B-GGUF UD-Q4_K_XL --card 5090
#   hf-download bartowski/Llama-3.2-3B-Instruct-GGUF IQ4_XS --card 5090,4070ti
#   hf-download --remove Llama-3.2-3B-Instruct-IQ4_XS --card 4070ti
#
# Library:  ~/.cache/huggingface/hub (hf CLI default cache)
# Per card: ~/.local/share/llama.cpp/cards/<card>/<name>/<file(s)>.gguf
#           the router's model id is <name>; default <name> = file name minus
#           .gguf and minus the -0000N-of-0000M split suffix.
# Then:     refresh-presets.py --card <card> --write (hardware-fitted ctx per
#           model) and a restart of llama-cpp-<card> if it is running (the
#           router scans its dir at startup only).
# Set HF_DOWNLOAD_NO_REFRESH=1 to skip the refresh + restart (batch use).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
MODELS="${SCRIPT_DIR}/llama-models.py"
REFRESH="${SCRIPT_DIR}/refresh-presets.py"

usage() { sed -n '2,22p' "$(readlink -f "${BASH_SOURCE[0]}")" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

REPO="" FILTER="" CARDS="" NAME="" REMOVE="" LIST=0
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage ;;
        --card) CARDS="${2:?--card needs a value}"; shift 2 ;;
        --card=*) CARDS="${1#*=}"; shift ;;
        --name) NAME="${2:?--name needs a value}"; shift 2 ;;
        --remove) REMOVE="${2:?--remove needs a model name}"; shift 2 ;;
        --list) LIST=1; shift ;;
        -*) echo "hf-download: unknown option $1" >&2; usage 2 ;;
        *) if [ -z "$REPO" ]; then REPO="$1"; elif [ -z "$FILTER" ]; then FILTER="$1";
           else echo "hf-download: unexpected argument $1" >&2; usage 2; fi; shift ;;
    esac
done

if [ "$LIST" = 1 ]; then exec python3 "$MODELS" list; fi

refresh_and_restart() {  # refresh_and_restart <card>...
    if [ "${HF_DOWNLOAD_NO_REFRESH:-0}" = 1 ]; then
        echo "  (HF_DOWNLOAD_NO_REFRESH=1: presets + restart deferred)"; return 0
    fi
    local card presets
    for card in "$@"; do
        presets="${HOME}/.config/containers/config/llama-cpp-${card}/presets.ini"
        if [ -f "$presets" ]; then
            if python3 "$REFRESH" --card "$card" --write >/dev/null; then
                echo "  presets refreshed: $presets"
            else
                echo "  ! refresh-presets.py --card $card failed (run it by hand to see why)"
            fi
        else
            echo "  ~ no $presets yet (run install.sh); presets not refreshed"
        fi
        if systemctl --user is-active --quiet "llama-cpp-${card}.service"; then
            echo "  restarting llama-cpp-${card} (the router scans its models dir at startup)"
            systemctl --user restart "llama-cpp-${card}.service" || true
        fi
    done
}

[ -n "$CARDS" ] || { echo "hf-download: --card 5090|4070ti|both[,...] is required" >&2; usage 2; }
IFS=, read -r -a CARD_LIST <<<"$CARDS"
for c in "${CARD_LIST[@]}"; do
    case "$c" in 5090|4070ti|both) ;;
        *) echo "hf-download: unknown card '$c' (5090 | 4070ti | both)" >&2; exit 2 ;; esac
done

if [ -n "$REMOVE" ]; then
    python3 "$MODELS" unlink "$REMOVE" --card "$CARDS"
    refresh_and_restart "${CARD_LIST[@]}"
    exit 0
fi

[ -n "$REPO" ] || usage 2
FILTER="${FILTER:-*.gguf}"
case "$FILTER" in
    *.gguf|*\**) ;;                   # already a file name or glob
    *) FILTER="*${FILTER}*.gguf" ;;   # bare quant, e.g. IQ4_XS
esac

command -v hf >/dev/null 2>&1 || {
    echo "hf-download: the Hugging Face CLI 'hf' is not installed:" >&2
    echo "  sudo pacman -S python-huggingface-hub" >&2
    exit 1
}

echo "=== hf-download: $REPO  [$FILTER] -> cards: $CARDS"
# Match the pattern at the repo root and in subfolders (some repos keep each
# quant's split parts in a folder of its own).
hf download "$REPO" --include "$FILTER" --include "*/$FILTER" >/dev/null
python3 "$MODELS" link "$REPO" "$FILTER" --card "$CARDS" ${NAME:+--name "$NAME"}
refresh_and_restart "${CARD_LIST[@]}"
echo "Done. Models per card: hf-download --list"
