# GPU Assignment

## How GPU detection works

When you run `./scripts/detect-gpus.sh`, the script:

1. Scans all available NVIDIA GPUs using `nvidia-smi`
2. Extracts each GPU's **index**, **name**, **UUID**, and **VRAM** (in MiB)
3. Sorts GPUs by VRAM descending (most VRAM → highest priority)
4. Assigns GPUs to llama.cpp services using the **GPU UUID**

## Assignment scheme

| Priority | GPU (sorted by VRAM) | Service name | Port |
|---|---|---|---|
| 1st (largest VRAM) | e.g. RTX 5090 (32 GB) | `llama-cpp-main` | `11435` |
| 2nd | e.g. RTX 4070 Ti (12 GB) | `llama-cpp-research` | `11436` |
| 3rd | e.g. RTX 4080 (16 GB) | `llama-cpp-extra-1` | `11431` |
| 4th | ... | `llama-cpp-extra-2` | `11432` |
| No GPU | CPU | `llama-cpp-main` | `11435` |

> **Why UUIDs?** Quadlet's `AddDevice=nvidia.com/gpu=GPU-xxxx` accepts UUIDs,
> not indices. Using UUIDs guarantees the correct GPU is assigned even if the
> PCIe topology changes (e.g. after a BIOS update or re-seating cards).

## VRAM profiles

Each GPU gets a tuned configuration profile based on its available VRAM.

### Profile: `vram_very_high` (28 GB+, e.g., RTX 5090, A6000)

```ini
LLAMA_ARG_CTX_SIZE=262144
LLAMA_ARG_CACHE_TYPE_K=q8_0
LLAMA_ARG_CACHE_TYPE_V=q8_0
LLAMA_ARG_BATCH=1024
LLAMA_ARG_UBATCH=256
```

Best for: Large models (27B+), maximum context length, multi-model hosting.

### Profile: `vram_high` (20-27 GB, e.g., RTX 4090 24 GB)

```ini
LLAMA_ARG_CTX_SIZE=131072
LLAMA_ARG_CACHE_TYPE_K=q8_0
LLAMA_ARG_CACHE_TYPE_V=q8_0
LLAMA_ARG_BATCH=1024
LLAMA_ARG_UBATCH=256
```

Best for: Large models with moderate context.

### Profile: `vram_medium` (10-19 GB, e.g., RTX 4070 Ti, RTX 4080)

```ini
LLAMA_ARG_CTX_SIZE=32768
LLAMA_ARG_CACHE_TYPE_K=q4_0
LLAMA_ARG_CACHE_TYPE_V=q4_0
LLAMA_ARG_BATCH=512
LLAMA_ARG_UBATCH=128
```

Best for: Mid-sized models (10-15B), conservative context to fit in limited VRAM.

### Profile: `vram_low` (< 10 GB, e.g., laptop GPUs)

```ini
LLAMA_ARG_CTX_SIZE=16384
LLAMA_ARG_CACHE_TYPE_K=q4_0
LLAMA_ARG_CACHE_TYPE_V=q4_0
LLAMA_ARG_BATCH=256
LLAMA_ARG_UBATCH=64
```

Best for: Small models (1-8B), limited context.

### CPU fallback

When no NVIDIA GPU is detected, a CPU-only llama.cpp service is deployed:

```ini
Image=ghcr.io/ggml-org/llama.cpp:server
No GPU device assignment.
LLAMA_ARG_CTX_SIZE=32768
LLAMA_ARG_N_GPU_LAYERS=0
```

## Manual override

You can manually edit the generated `.container` files to change GPU
assignments. Regenerate with `./scripts/detect-gpus.sh` after making
hardware changes.

## Troubleshooting

### "Could not enable llama-cpp-main.service"

Check: `systemctl --user status llama-cpp-main.service`

Common issues:
- GPU UUID mismatch (GPU replaced or BIOS changed): re-run `detect-gpus.sh`
- nvidia-container-toolkit not installed: `rpm-ostree install nvidia-container-toolkit`
- Rootless podman can't access GPU: check `podman info | grep runtime`
- GPU UUID may have changed: run `nvidia-smi -L` and compare with the UUID
  in the quadlet file.

To verify GPU accessibility from a container:

```bash
podman run --rm --device=nvidia.com/gpu=all \
    ghcr.io/ggml-org/llama.cpp:server-cuda nvidia-smi
```