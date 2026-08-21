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
# Uses the `hf` CLI (huggingface_hub ≥ 0.38). Falls back to huggingface-cli.

set -euo pipefail

MODELS_DIR="${HOME}/.local/share/llama.cpp/models"
PRESET_FILE="${HOME}/.config/containers/config/llama.cpp/presets.ini"

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
DOWNLOAD_CMD=""
if command -v hf &>/dev/null; then
    DOWNLOAD_CMD="hf"
elif command -v huggingface-cli &>/dev/null; then
    DOWNLOAD_CMD="huggingface-cli"
else
    echo "Error: neither 'hf' nor 'huggingface-cli' found."
    echo "Install one of:"
    echo "  brew install huggingface-cli"
    echo "  pip install huggingface-hub"
    echo "  uv tool install huggingface-hub"
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
if [ "$DOWNLOAD_CMD" = "hf" ]; then
    hf download "$REPO" --include "$FILTER" --local-dir "$TARGET_DIR" \
        || { echo "Download failed (filter may match nothing)."; exit 1; }
else
    huggingface-cli download "$REPO" "$FILTER" \
        --local-dir "$TARGET_DIR" \
        --resume-download \
        || { echo "Download failed (filter may match nothing)."; exit 1; }
fi
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

# ─── Register in presets.ini ─────────────────────────────────────────────
mkdir -p "$(dirname "$PRESET_FILE")"
[ -f "$PRESET_FILE" ] || touch "$PRESET_FILE"

for f in "${GGUF_FILES[@]}"; do
    BASENAME=$(basename "$f" .gguf)

    if grep -q "^\[${BASENAME}\]" "$PRESET_FILE" 2>/dev/null; then
        echo "  ✓ ${BASENAME}: already in presets.ini (skipped)"
        continue
    fi

    cat >> "$PRESET_FILE" <<INI

[${BASENAME}]
m = /models/${REPO_SLUG}/$(basename "$f")
ctx-size = 32768
temp = 0.7
top-p = 0.95
INI
    echo "  ✓ ${BASENAME}: added to presets.ini"
done

# ─── Restart llama.cpp ────────────────────────────────────────────────────
if systemctl --user is-active llama-cpp-main.service &>/dev/null; then
    echo ""
    echo "Restarting llama-cpp-main.service to pick up new model..."
    systemctl --user restart llama-cpp-main.service || true
fi

echo ""
echo "Done. Verify with: curl http://127.0.0.1:11435/v1/models"