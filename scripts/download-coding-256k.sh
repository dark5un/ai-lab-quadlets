#!/usr/bin/env bash
# download-coding-256k.sh — Download verified 262,144-context coding GGUF models
# (llama.cpp-runnable, non-vLLM) in series, via hf-download.sh, then refresh
# per-model presets with hardware-fitted ctx.
#
# These repos were verified to be real GGUF with n_ctx_train = 262144 by
# reading the GGUF header (refresh-presets.py parser). Models:
#   Terathox-Coder/Qwen3.8-27B-MTP-GGUF   (qwen35, 27B, clean)
#   Jab1718/qwen3.8-flash-coder-26gb-gguf (qwen4exp, coding)
#
# Set --only=<n> to download a single entry by its line index below.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HF_DL="${SCRIPT_DIR}/hf-download.sh"
REFRESH="${SCRIPT_DIR}/refresh-presets.py"

# name|repo|quant-filter(glob)
ENTRIES=(
  "Qwen3.8-27B-MTP|Terathox-Coder/Qwen3.8-27B-MTP-GGUF|Q4_K_M"
  "Qwen3.8-Flash-Coder-26GB|Jab1718/qwen3.8-flash-coder-26gb-gguf|Q4_K_M"
)

ONLY=""
[[ "${1:-}" == --only=* ]] && ONLY="${1#--only=}"

start=0
end=${#ENTRIES[@]}
if [ -n "$ONLY" ]; then
  start=$((ONLY-1)); end=$((ONLY))
fi

for i in $(seq $((start+1)) $end); do
  line="${ENTRIES[$((i-1))]}"
  name="${line%%|*}"
  rest="${line#*|}"
  repo="${rest%%|*}"
  quant="${rest#*|}"
  echo ""
  echo "════════ $i/${#ENTRIES[@]} : $name ($repo) ════════"
  if ! command -v hf >/dev/null 2>&1; then
    echo "  ! 'hf' CLI missing — install huggingface_hub CLI first"; exit 1
  fi
  "$HF_DL" "$repo" "$quant" || { echo "  ✗ failed to download $repo"; continue; }
  echo "  → refreshing presets for $name..."
  python3 "$REFRESH" --write || echo "  ! refresh-presets.py failed"
done

echo ""
echo "Done. Verify model discovery with:"
echo "  curl http://127.0.0.1:11435/v1/models"
