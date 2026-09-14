#!/usr/bin/env bash
# hf-download — Download a GGUF model from HuggingFace with a specific
# quantization, place it where llama.cpp expects, and register it in presets.ini.
#
# Usage:
#   hf-download <repo> [filter]
#
# Examples:
#   hf-download unsloth/Qwen3.8-27B-GGUF UD-IQ1_M
#   hf-download bartowski/Llama-3.2-3B-Instruct-GGUF IQ4_XS
#   hf-download unsloth/Qwen3.8-27B-GGUF            (downloads all *.gguf)
#
# Downloads to: ~/.local/share/llama.cpp/models/
# Updates:      ~/.config/containers/config/llama.cpp/presets.ini
#
# Requires the `hf` CLI (huggingface_hub).

set -euo pipefail

MODELS_DIR="${HOME}/.local/share/llama.cpp/models"

usage() {
    echo "Usage: hf-download <repo> [quantization-or-filter]"
    echo ""
    echo "Examples:"
    echo "  hf-download unsloth/Qwen3.8-27B-GGUF UD-IQ1_M"
    echo "  hf-download bartowski/Llama-3.2-3B-Instruct-GGUF IQ4_XS"
    echo "  hf-download unsloth/Qwen3.8-27B-GGUF"
    exit 0
}

[ $# -lt 1 ] && usage
[[ "$1" == "-h" || "$1" == "--help" ]] && usage

REPO="$1"
FILTER="${2:-*.gguf}"

# Allow bare quant like "UD-IQ1_M" → "*UD-IQ1_M*.gguf" pattern
case "$FILTER" in
    *\.gguf) ;;                    # already a filename pattern
    *\**) ;;                       # already a glob
    *) FILTER="*${FILTER}*.gguf" ;; # bare quant → glob
esac

# ─── Prerequisites ────────────────────────────────────────────────────────
if ! command -v hf &>/dev/null; then
    echo "Error: Hugging Face CLI (hf) not found."
    echo "Install one of:"
    echo "  brew install hf"
    echo "  pip install huggingface_hub"
    echo "  curl -LsSf https://hf.co/cli/install.sh | bash"
    exit 1
fi

# ─── Target directory ─────────────────────────────────────────────────────
REPO_SLUG=$(basename "$REPO")
TARGET_DIR="${MODELS_DIR}/${REPO_SLUG}"
mkdir -p "$TARGET_DIR"

echo "=== hf-download ==="
echo "  Repo:   $REPO"
echo "  Filter: $FILTER"
echo "  Target: $TARGET_DIR"
echo ""

# ─── Download ─────────────────────────────────────────────────────────────
echo "Downloading (this may take a while)..."
hf download "$REPO" --include "$FILTER" --local-dir "$TARGET_DIR" \
    || { echo "Download failed (filter may match nothing)."; exit 1; }
echo ""

# ─── Find what we got ─────────────────────────────────────────────────────
GGUF_FILES=()
while IFS= read -r f; do
    GGUF_FILES+=("$f")
done < <(find "$TARGET_DIR" -maxdepth 1 -name "*.gguf" 2>/dev/null | sort)

if [ ${#GGUF_FILES[@]} -eq 0 ]; then
    echo "No .gguf files matched '$FILTER' in $REPO."
    exit 1
fi

echo "Downloaded ${#GGUF_FILES[@]} file(s):"
for f in "${GGUF_FILES[@]}"; do
    echo "  • $(basename "$f")  ($(du -h "$f" | cut -f1))"
done
echo ""

# ─── Register in presets.ini via the hardware calculator ────────────────
# Delegate to refresh-presets.py so the value is computed from the real GGUF
# (train-capped native ctx), not hardcoded, and sections use the directory
# name that matches the llama.cpp router model id. Avoids the filename-vs-
# directory convention clash and the router-stripped `m =` key.
#
# Set HF_DOWNLOAD_NO_REFRESH=1 to skip refresh AND restart — used by
# download-gguf-series.sh which defers both until every model has landed.
if [ "${HF_DOWNLOAD_NO_REFRESH:-0}" = "1" ]; then
    echo "  (HF_DOWNLOAD_NO_REFRESH=1 — deferring preset refresh + restart)"
    echo ""
    echo "Done. Verify with: curl http://127.0.0.1:11435/v1/models"
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REFRESH="${SCRIPT_DIR}/refresh-presets.py"
if [ ! -f "$REFRESH" ]; then
    echo "  ! refresh-presets.py not found next to hf-download (${REFRESH})"
    echo "    Downloaded but NOT registered. Run it manually after configuring models."
else
    echo "  → Refreshing per-model presets with hardware-fitted ctx..."
    python3 "$REFRESH" --write || echo "  ! refresh-presets.py failed (see above)"
fi

# ─── Restart llama.cpp ────────────────────────────────────────────────────
if systemctl --user is-active llama-cpp-main.service &>/dev/null; then
    echo ""
    echo "Restarting llama-cpp-main.service to pick up new model..."
    systemctl --user restart llama-cpp-main.service || true
fi

echo ""
echo "Done. Verify with: curl http://127.0.0.1:11435/v1/models"