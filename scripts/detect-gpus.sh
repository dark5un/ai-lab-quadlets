#!/usr/bin/env bash
# detect-gpus.sh — Detect NVIDIA GPUs and generate appropriate llama.cpp quadlets
#
# Scans the system for NVIDIA GPUs, sorts them by VRAM (largest first), and
# generates:
#   - llama-cpp-main.container  → largest VRAM GPU   (port 11435)
#   - llama-cpp-research.container → 2nd largest GPU  (port 11436)
#   - llama-cpp-extra-N.container  → 3rd+ GPUs        (port 1N43N)
#   - Config with VRAM-tuned settings per service
#
# If no NVIDIA GPU is found, a single CPU-based llama-cpp quadlet is deployed.
#
# Usage:
#   ./scripts/detect-gpus.sh [--output-dir quadlets] [--config-dir config]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

OUTPUT_DIR="${PROJECT_DIR}/quadlets"
CONFIG_DIR="${PROJECT_DIR}/config"
TEMPLATE_DIR="${SCRIPT_DIR}/templates"
KEYS_FILE="${CONFIG_DIR}/llama.cpp/keys.txt"

# ─── VRAM-based tuning profiles ──────────────────────────────────────────
# Each profile defines settings appropriate for a given VRAM tier.
profile_for_vram() {
    local vram_gb=$1

    if (( $(echo "$vram_gb >= 28" | bc -l) )); then
        # 28 GB+ (RTX 5090 32 GB, RTX 4090 24 GB, A6000 48 GB)
        echo "vram_very_high"
    elif (( $(echo "$vram_gb >= 20" | bc -l) )); then
        # 20-27 GB (RTX 4090 24 GB)
        echo "vram_high"
    elif (( $(echo "$vram_gb >= 10" | bc -l) )); then
        # 10-19 GB (RTX 4070 Ti 12 GB, RTX 4080 16 GB)
        echo "vram_medium"
    else
        # < 10 GB (RTX 4060 8 GB, laptop GPUs)
        echo "vram_low"
    fi
}

# Profile settings
get_profile_setting() {
    local profile=$1
    local key=$2

    case "$profile:$key" in
        vram_very_high:CTX_SIZE)  echo "262144" ;;
        vram_very_high:CACHE_K)   echo "q8_0" ;;
        vram_very_high:CACHE_V)   echo "q8_0" ;;
        vram_very_high:BATCH)     echo "1024" ;;
        vram_very_high:UBATCH)    echo "256" ;;
        vram_very_high:DEFAULT_CTX) echo "131072" ;;
        vram_very_high:MEMORY_MAX) echo "64" ;;

        vram_high:CTX_SIZE)  echo "131072" ;;
        vram_high:CACHE_K)   echo "q8_0" ;;
        vram_high:CACHE_V)   echo "q8_0" ;;
        vram_high:BATCH)     echo "1024" ;;
        vram_high:UBATCH)    echo "256" ;;
        vram_high:DEFAULT_CTX) echo "65536" ;;
        vram_high:MEMORY_MAX) echo "48" ;;

        vram_medium:CTX_SIZE)  echo "32768" ;;
        vram_medium:CACHE_K)   echo "q4_0" ;;
        vram_medium:CACHE_V)   echo "q4_0" ;;
        vram_medium:BATCH)     echo "512" ;;
        vram_medium:UBATCH)    echo "128" ;;
        vram_medium:DEFAULT_CTX) echo "16384" ;;
        vram_medium:MEMORY_MAX) echo "24" ;;

        vram_low:CTX_SIZE)  echo "16384" ;;
        vram_low:CACHE_K)   echo "q4_0" ;;
        vram_low:CACHE_V)   echo "q4_0" ;;
        vram_low:BATCH)     echo "256" ;;
        vram_low:UBATCH)    echo "64" ;;
        vram_low:DEFAULT_CTX) echo "8192" ;;
        vram_low:MEMORY_MAX) echo "12" ;;

        *) echo "ERROR: unknown profile/key $profile:$key" >&2; return 1 ;;
    esac
}

# ─── GPU detection ────────────────────────────────────────────────────────
detect_gpus() {
    if ! command -v nvidia-smi &>/dev/null; then
        echo "WARNING: nvidia-smi not found — no NVIDIA GPUs detected." >&2
        return 1
    fi

    # Parse GPU info: index, name, uuid, memory.total (MiB)
    nvidia-smi --query-gpu=index,name,uuid,memory.total --format=csv,noheader 2>/dev/null || return 1
}

# ─── File generation helpers ──────────────────────────────────────────────
substitute_template() {
    local template=$1
    local output=$2
    shift 2

    local content
    content=$(cat "$template")

    # Apply substitutions passed as key=value pairs
    while [ $# -gt 0 ]; do
        local key="${1%%=*}"
        local val="${1#*=}"
        content="${content//\{${key}\}/${val}}"
        shift
    done

    mkdir -p "$(dirname "$output")"
    echo "$content" > "$output"
    echo "  → Generated: $output"
}

generate_service_env() {
    local output=$1
    local profile=$2
    local gpu_name=$3
    local gpu_vram=$4
    local header_comment="# Primary GPU: $gpu_name (${gpu_vram} GB)"

    local ctx_size cache_k cache_v batch ubatch
    ctx_size=$(get_profile_setting "$profile" CTX_SIZE)
    cache_k=$(get_profile_setting "$profile" CACHE_K)
    cache_v=$(get_profile_setting "$profile" CACHE_V)
    batch=$(get_profile_setting "$profile" BATCH)
    ubatch=$(get_profile_setting "$profile" UBATCH)

    # Read the .env.example and substitute
    local env_template="${output}.example"
    if [ ! -f "$env_template" ]; then
        echo "  WARNING: template $env_template not found, using defaults" >&2
        # Write minimal env
        cat > "$output" <<ENVEOF
# llama.cpp service.env — $gpu_name (${gpu_vram} GB)
LLAMA_ARG_MODELS_DIR=/models
LLAMA_ARG_MODELS_MAX=1
LLAMA_ARG_MODELS_AUTOLOAD=true
LLAMA_ARG_MODELS_PRESET=/etc/llama-cpp/presets.ini
LLAMA_ARG_API_KEY_FILE=/etc/llama-cpp/keys.txt
LLAMA_ARG_LOAD_MODE=none
LLAMA_ARG_HOST=0.0.0.0
LLAMA_ARG_PORT=8080
LLAMA_ARG_CTX_SIZE=${ctx_size}
LLAMA_ARG_N_PARALLEL=1
LLAMA_ARG_N_PREDICT=-1
LLAMA_ARG_N_GPU_LAYERS=all
LLAMA_ARG_SPLIT_MODE=none
LLAMA_ARG_MAIN_GPU=0
LLAMA_ARG_KV_OFFLOAD=true
LLAMA_ARG_FLASH_ATTN=on
LLAMA_ARG_CACHE_TYPE_K=${cache_k}
LLAMA_ARG_CACHE_TYPE_V=${cache_v}
LLAMA_ARG_BATCH=${batch}
LLAMA_ARG_UBATCH=${ubatch}
LLAMA_ARG_FIT=off
LLAMA_ARG_JINJA=true
LLAMA_ARG_ENDPOINT_METRICS=true
LLAMA_ARG_ENDPOINT_SLOTS=true
LLAMA_ARG_TIMEOUT=3600
LLAMA_ARG_SSE_PING_INTERVAL=30
ENVEOF
        echo "  → Generated: $output"
        return
    fi

    substitute_template "$env_template" "$output" \
        "GPU_ENV_HEADER=$header_comment" \
        "CTX_SIZE=$ctx_size" \
        "CACHE_K=$cache_k" \
        "CACHE_V=$cache_v" \
        "BATCH=$batch" \
        "UBATCH=$ubatch"
}

generate_presets_ini() {
    local output=$1
    local profile=$2
    local gpu_name=$3
    local gpu_vram=$4

    local default_ctx cache_k cache_v
    default_ctx=$(get_profile_setting "$profile" DEFAULT_CTX)
    cache_k=$(get_profile_setting "$profile" CACHE_K)
    cache_v=$(get_profile_setting "$profile" CACHE_V)

    cat > "$output" <<INIEOF
# llama.cpp per-model presets — $gpu_name (${gpu_vram} GB)
# Generated by scripts/detect-gpus.sh

version = 1

; Global defaults for this GPU
[*]
ctx-size = ${default_ctx}
n-predict = -1
n-gpu-layers = all
split-mode = none
main-gpu = 0
kv-offload = true
flash-attn = on
cache-type-k = ${cache_k}
cache-type-v = ${cache_v}
fit = off
jinja = on
load-mode = mmap

; ─── Per-model overrides ──────────────────────────────────────────────
; Uncomment and edit to tune specific models for this GPU:
;
; [model-name]
; m = /models/path/to/model.gguf
; ctx-size = ${default_ctx}
; temp = 0.7
; top-p = 0.95

INIEOF
    echo "  → Generated: $output"
}

# ─── Main ─────────────────────────────────────────────────────────────────
main() {
    echo "=== AI Lab Quadlets — GPU Detection ==="
    echo ""

    # Parse args
    while [ $# -gt 0 ]; do
        case "$1" in
            --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
            --config-dir) CONFIG_DIR="$2"; shift 2 ;;
            *) echo "Unknown option: $1"; exit 1 ;;
        esac
    done

    mkdir -p "$OUTPUT_DIR"

    # Detect GPUs
    GPU_DATA=$(detect_gpus || true)

    if [ -z "$GPU_DATA" ]; then
        echo "No NVIDIA GPUs detected."
        echo "→ Deploying CPU-based llama.cpp service."
        echo ""

        # Copy CPU quadlet
        cp "${PROJECT_DIR}/quadlets/llama-cpp-cpu.container" "${OUTPUT_DIR}/llama-cpp-main.container"
        echo "  → Copied: llama-cpp-main.container (CPU version)"

        # Generate CPU service env
        mkdir -p "${CONFIG_DIR}/llama.cpp"
        cat > "${CONFIG_DIR}/llama.cpp/service.env" <<CPUENV
# llama.cpp service.env — CPU-only
LLAMA_ARG_MODELS_DIR=/models
LLAMA_ARG_MODELS_MAX=1
LLAMA_ARG_MODELS_AUTOLOAD=true
LLAMA_ARG_MODELS_PRESET=/etc/llama-cpp/presets.ini
LLAMA_ARG_LOAD_MODE=none
LLAMA_ARG_HOST=0.0.0.0
LLAMA_ARG_PORT=8080
LLAMA_ARG_CTX_SIZE=32768
LLAMA_ARG_N_PARALLEL=1
LLAMA_ARG_N_PREDICT=-1
LLAMA_ARG_UBATCH=128
LLAMA_ARG_BATCH=512
LLAMA_ARG_FIT=off
LLAMA_ARG_JINJA=true
LLAMA_ARG_ENDPOINT_METRICS=true
LLAMA_ARG_ENDPOINT_SLOTS=true
LLAMA_ARG_TIMEOUT=3600
LLAMA_ARG_SSE_PING_INTERVAL=30
CPUENV
        echo "  → Generated: ${CONFIG_DIR}/llama.cpp/service.env"

        # Generate CPU presets
        cat > "${CONFIG_DIR}/llama.cpp/presets.ini" <<CPUPRE
# llama.cpp per-model presets — CPU
# Generated by scripts/detect-gpus.sh

version = 1

[*]
ctx-size = 8192
n-predict = -1
n-gpu-layers = 0
fit = off
jinja = on
load-mode = mmap

CPUPRE
        echo "  → Generated: ${CONFIG_DIR}/llama.cpp/presets.ini"

        # No research GPU service
        echo ""
        echo "GPU detection complete — CPU-only mode."
        echo "No research llama-cpp service needed (single CPU instance)."
        return 0
    fi

    # Parse GPU lines: "0, NVIDIA GeForce RTX 5090, GPU-xxxxxxxx, 32768 MiB"
    echo "Detected GPUs:"
    echo "$GPU_DATA" | while IFS= read -r line; do
        echo "  $line"
    done
    echo ""

    # Sort by VRAM (last field, MiB) descending
    SORTED_GPUS=$(echo "$GPU_DATA" | sort -t, -k4 -rn)

    # Process primary GPU (largest VRAM)
    PRIMARY_LINE=$(echo "$SORTED_GPUS" | head -1)
    PRIMARY_INDEX=$(echo "$PRIMARY_LINE" | cut -d, -f1 | xargs)
    PRIMARY_NAME=$(echo "$PRIMARY_LINE" | cut -d, -f2 | xargs)
    PRIMARY_UUID=$(echo "$PRIMARY_LINE" | cut -d, -f3 | xargs)
    PRIMARY_VRAM_MIB=$(echo "$PRIMARY_LINE" | cut -d, -f4 | xargs)
    PRIMARY_VRAM_GB=$(echo "scale=0; $PRIMARY_VRAM_MIB / 1024" | bc)
    PRIMARY_PROFILE=$(profile_for_vram "$PRIMARY_VRAM_GB")

    echo "=== Primary GPU (largest VRAM) ==="
    echo "  GPU $PRIMARY_INDEX: $PRIMARY_NAME ($PRIMARY_VRAM_GB GB)"
    echo "  UUID: $PRIMARY_UUID"
    echo "  Profile: $PRIMARY_PROFILE"
    echo ""

    # Generate primary configs
    mkdir -p "${CONFIG_DIR}/llama.cpp"
    generate_service_env "${CONFIG_DIR}/llama.cpp/service.env" "$PRIMARY_PROFILE" "$PRIMARY_NAME" "$PRIMARY_VRAM_GB"
    generate_presets_ini "${CONFIG_DIR}/llama.cpp/presets.ini" "$PRIMARY_PROFILE" "$PRIMARY_NAME" "$PRIMARY_VRAM_GB"

    # Ensure keys.txt exists
    if [ ! -f "$KEYS_FILE" ]; then
        echo "12345" > "$KEYS_FILE"
        echo "  → Created: $KEYS_FILE (placeholder key)"
    fi

    # Generate primary quadlet
    MEMORY_MAX=$(get_profile_setting "$PRIMARY_PROFILE" MEMORY_MAX)
    substitute_template "${TEMPLATE_DIR}/llama-cpp-main.container.in" "${OUTPUT_DIR}/llama-cpp-main.container" \
        "GPU_NAME=$PRIMARY_NAME" \
        "GPU_VRAM=$PRIMARY_VRAM_GB" \
        "GPU_UUID=$PRIMARY_UUID" \
        "MEMORY_MAX=$MEMORY_MAX"

    # Process secondary GPU (second largest)
    SECONDARY_LINE=$(echo "$SORTED_GPUS" | sed -n '2p')
    if [ -n "$SECONDARY_LINE" ]; then
        SECONDARY_INDEX=$(echo "$SECONDARY_LINE" | cut -d, -f1 | xargs)
        SECONDARY_NAME=$(echo "$SECONDARY_LINE" | cut -d, -f2 | xargs)
        SECONDARY_UUID=$(echo "$SECONDARY_LINE" | cut -d, -f3 | xargs)
        SECONDARY_VRAM_MIB=$(echo "$SECONDARY_LINE" | cut -d, -f4 | xargs)
        SECONDARY_VRAM_GB=$(echo "scale=0; $SECONDARY_VRAM_MIB / 1024" | bc)
        SECONDARY_PROFILE=$(profile_for_vram "$SECONDARY_VRAM_GB")

        echo "=== Secondary GPU ==="
        echo "  GPU $SECONDARY_INDEX: $SECONDARY_NAME ($SECONDARY_VRAM_GB GB)"
        echo "  UUID: $SECONDARY_UUID"
        echo "  Profile: $SECONDARY_PROFILE"
        echo ""

        # Generate secondary configs
        mkdir -p "${CONFIG_DIR}/llama.cpp-research"
        generate_service_env "${CONFIG_DIR}/llama.cpp-research/service.env" "$SECONDARY_PROFILE" "$SECONDARY_NAME" "$SECONDARY_VRAM_GB"
        generate_presets_ini "${CONFIG_DIR}/llama.cpp-research/presets.ini" "$SECONDARY_PROFILE" "$SECONDARY_NAME" "$SECONDARY_VRAM_GB"

        # Generate secondary quadlet
        MEMORY_MAX=$(get_profile_setting "$SECONDARY_PROFILE" MEMORY_MAX)
        substitute_template "${TEMPLATE_DIR}/llama-cpp-research.container.in" "${OUTPUT_DIR}/llama-cpp-research.container" \
            "GPU_NAME=$SECONDARY_NAME" \
            "GPU_VRAM=$SECONDARY_VRAM_GB" \
            "GPU_UUID=$SECONDARY_UUID" \
            "MEMORY_MAX=$MEMORY_MAX"
    else
        echo "No secondary GPU detected — skipping research llama-cpp service."
        # Clean up any stale research files
        rm -f "${OUTPUT_DIR}/llama-cpp-research.container"
    fi

    # Process extra GPUs (3rd, 4th, ...)
    EXTRA_INDEX=0
    echo "$SORTED_GPUS" | tail -n +3 | while IFS= read -r line; do
        [ -z "$line" ] && continue
        EXTRA_INDEX=$((EXTRA_INDEX + 1))

        EXTRA_GPU_INDEX=$(echo "$line" | cut -d, -f1 | xargs)
        EXTRA_NAME=$(echo "$line" | cut -d, -f2 | xargs)
        EXTRA_UUID=$(echo "$line" | cut -d, -f3 | xargs)
        EXTRA_VRAM_MIB=$(echo "$line" | cut -d, -f4 | xargs)
        EXTRA_VRAM_GB=$(echo "scale=0; $EXTRA_VRAM_MIB / 1024" | bc)
        EXTRA_PROFILE=$(profile_for_vram "$EXTRA_VRAM_GB")

        echo "=== Extra GPU #${EXTRA_INDEX} (GPU $EXTRA_GPU_INDEX) ==="
        echo "  $EXTRA_NAME ($EXTRA_VRAM_GB GB)"
        echo "  UUID: $EXTRA_UUID"
        echo ""

        # Generate extra configs
        mkdir -p "${CONFIG_DIR}/llama.cpp-extra-${EXTRA_INDEX}"
        generate_service_env "${CONFIG_DIR}/llama.cpp-extra-${EXTRA_INDEX}/service.env" "$EXTRA_PROFILE" "$EXTRA_NAME" "$EXTRA_VRAM_GB"
        generate_presets_ini "${CONFIG_DIR}/llama.cpp-extra-${EXTRA_INDEX}/presets.ini" "$EXTRA_PROFILE" "$EXTRA_NAME" "$EXTRA_VRAM_GB"

        # Generate extra quadlet
        MEMORY_MAX=$(get_profile_setting "$EXTRA_PROFILE" MEMORY_MAX)
        substitute_template "${TEMPLATE_DIR}/llama-cpp-extra.container.in" "${OUTPUT_DIR}/llama-cpp-extra-${EXTRA_INDEX}.container" \
            "GPU_NAME=$EXTRA_NAME" \
            "GPU_VRAM=$EXTRA_VRAM_GB" \
            "GPU_UUID=$EXTRA_UUID" \
            "INDEX=${EXTRA_INDEX}" \
            "MEMORY_MAX=$MEMORY_MAX"
    done

    echo ""
    echo "=== GPU Detection Complete ==="
    echo "Primary:  $PRIMARY_NAME at port 11435"
    if [ -n "$SECONDARY_LINE" ]; then
        echo "Research: $SECONDARY_NAME at port 11436"
    fi
    if [ "$EXTRA_INDEX" -gt 0 ]; then
        echo "Extra:    $EXTRA_INDEX additional service(s)"
    fi
    echo ""
    echo "Quadlets written to: $OUTPUT_DIR/"
    echo "Configs written to:  $CONFIG_DIR/"
    echo ""
    echo "Run the following to deploy:"
    echo "  systemctl --user daemon-reload"
    echo "  systemctl --user enable --now ai-network.service"
    echo "  systemctl --user enable --now llama-cpp-main.service"
    echo "  # ... and any other services you want"
}

main "$@"