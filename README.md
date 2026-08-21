# AI Lab Quadlets

> **Reproducible self-hosted AI services on Universal Blue / Bluefin / any immutable Fedora.**

This repo packages a full self-hosted AI lab as Podman Quadlets — declarative container
units managed by systemd. Everything runs rootless on the immutable host, survives
reboots, and can be rehydrated on a fresh machine with one command.

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                   Host (Bluefin)                      │
│                                                       │
│  ai.network ──── podman network (internal)            │
│       │                                              │
│       ├── caddy:3001-3004  ──── HTTPS reverse proxy   │
│       │    ├─ :3001 → open-webui:8080                 │
│       │    ├─ :3002 → comfyui:8188                    │
│       │    ├─ :3003 → hermes:9119                     │
│       │    └─ :3004 → sketchlab:8080                  │
│       │                                              │
│       ├── llama-cpp-main:11435  ←─ largest GPU        │
│       │    └─ /models:ro                              │
│       │    └─ /presets.ini                            │
│       │                                              │
│       ├── llama-cpp-research:11436  ←─ 2nd GPU        │
│       │    └─ /models:ro                              │
│       │    └─ /presets.ini                            │
│       │                                              │
│       ├── open-webui:3000   ──── AI chat frontend     │
│       ├── comfyui:8188      ──── Image generation     │
│       ├── sketchlab:8080    ──── Diagram editor        │
│       └── hermes:9119       ──── AI agent gateway      │
└──────────────────────────────────────────────────────┘
```

## Services

| Service | Status | Port | Description |
|---|---|---|---|
| **ai-network** | core | — | Podman network for all container communication |
| **llama-cpp-main** | core | `11435` | llama.cpp on the largest GPU (long context, big models) |
| **llama-cpp-research** | optional | `11436` | llama.cpp on the 2nd GPU (conservative settings) |
| **open-webui** | web | `3000` | AI chat UI (OpenAI-compatible backend) |
| **caddy** | proxy | `3001-3004` | HTTPS reverse proxy, internal TLS |
| **comfyui** | image | `8188` | Stable Diffusion / AI image generation |
| **sketchlab** | diagram | `8080` | Diagramming SPA with local LLM support |
| **hermes** | agents | `9119` | Nous Research Hermes Agent gateway |

## Quick Install

```bash
# One command (requires git):
curl -fsSL https://raw.githubusercontent.com/dark5un/ai-lab-quadlets/main/install.sh | bash

# Or from a local checkout:
git clone https://github.com/dark5un/ai-lab-quadlets.git
cd ai-lab-quadlets
./install.sh
```

## Manual setup

### 1. Prerequisites

- **Bluefin** (or any Fedora Silverblue / ublue image)
- **Podman** (pre-installed on Bluefin)
- **NVIDIA drivers** (ublue-nvidia image, or install with `rpm-ostree install akmod-nvidia`)
- **nvidia-container-toolkit** (for GPU support):
  ```bash
  rpm-ostree install nvidia-container-toolkit
  systemctl reboot
  ```

### 2. Copy quadlets to the systemd directory

```bash
QUADLET_DIR="${HOME}/.config/containers/systemd"
CONFIG_DIR="${HOME}/.config/containers/config"

mkdir -p "$QUADLET_DIR" "$CONFIG_DIR"
cp quadlets/*.network "$QUADLET_DIR/"
cp quadlets/*.container "$QUADLET_DIR/"
cp -r config/* "$CONFIG_DIR/"
```

### 3. GPU detection

```bash
./scripts/detect-gpus.sh
```

This generates:
- `quadlets/llama-cpp-main.container` — pinned to the largest VRAM GPU
- `quadlets/llama-cpp-research.container` — pinned to the second GPU
- `config/llama.cpp/service.env` — VRAM-tuned env for the primary GPU
- `config/llama.cpp-research/service.env` — VRAM-tuned env for the secondary GPU
- `config/llama.cpp/presets.ini` — VRAM-tuned model presets
- `config/llama.cpp-research/presets.ini` — VRAM-tuned model presets

**No GPUs?** Falls back to a single CPU-based llama.cpp service.

### 4. Generate secrets

```bash
./scripts/generate-secrets.sh
```

Creates production-ready `.env` files with random passwords from the `.example` templates.

### 5. Deploy

```bash
systemctl --user daemon-reload
systemctl --user enable --now ai-network.service
systemctl --user enable --now llama-cpp-main.service

# Optional services:
systemctl --user enable --now caddy.service
systemctl --user enable --now open-webui.service
systemctl --user enable --now sketchlab.service
systemctl --user enable --now comfyui.service
systemctl --user enable --now hermes.service
```

### 6. Load models

Place GGUF model files in `~/.local/share/llama.cpp/models/`, then configure
per-model overrides in:
- `~/.config/containers/config/llama.cpp/presets.ini` (primary GPU)
- `~/.config/containers/config/llama.cpp-research/presets.ini` (secondary GPU)

## GPU detection details

The `detect-gpus.sh` script:

1. Runs `nvidia-smi --query-gpu=index,name,uuid,memory.total --format=csv,noheader`
2. Sorts GPUs by VRAM descending
3. Assigns the **largest** GPU → primary llama-cpp service (port **11435**)
4. Assigns the **second** GPU → research llama-cpp service (port **11436**)
5. Creates N+ llama-cpp services for additional GPUs (port **1N43N**)

### VRAM profiles

| VRAM | Profile | Context | KV Cache | Batch |
|---|---|---|---|---|
| 28 GB+ | very_high | 262,144 | Q8 | 1024 |
| 20-27 GB | high | 131,072 | Q8 | 1024 |
| 10-19 GB | medium | 32,768 | Q4 | 512 |
| < 10 GB | low | 16,384 | Q4 | 256 |

## Custom images

### Sketch Lab

The diagramming app requires a local build:

```bash
git clone https://github.com/dark5un/sketchlab.app.git
cd sketchlab.app
podman build -t localhost/sketchlab:v0.5.0 .
```

Or use the `containers/sketchlab/Containerfile` in this repo if the source is
available as a submodule.

### ComfyUI

The default quadlet uses `yanwk/comfyui-wrapper:cuda13` from Docker Hub.
For a custom build, place a Containerfile at `containers/comfyui/Containerfile`.

## Sketch Lab local models

Sketch Lab's AI panel connects to any OpenAI-compatible endpoint:

1. Open Sketch Lab (https://dark5un.local:3004)
2. Click the AI button in the editor
3. Set endpoint to: `http://llama-cpp:8080` (within the network)
   or `http://127.0.0.1:11435` (from the host)
4. Select a model from the dropdown (populated from `/v1/models`)

For AI agents: the Sketch Lab skill file is at
[github.com/dark5un/sketchlab.app](https://github.com/dark5un/sketchlab.app)
— see `SKILL.md` in the `.claude/skills/` directory.

## Roadmap

- [ ] Nix flake / home-manager module for Bluefin
- [ ] Pre-built custom images via GitHub Container Registry
- [ ] AMD ROCm GPU detection support
- [ ] ComfyUI workflow presets

## License

Apache 2.0 — see [LICENSE](LICENSE).