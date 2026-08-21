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
```

The installer is **idempotent** — safe to re-run on an already-installed system.
It detects the actual avahi/mDNS hostname so configs work on any machine.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/dark5un/ai-lab-quadlets/main/uninstall.sh | bash
```

Stops all services, removes quadlet files, preserves data and configs.

## Using `just` (recommended workflow)

```bash
git clone https://github.com/dark5un/ai-lab-quadlets.git
cd ai-lab-quadlets

just -f ai-lab.just install    # Install everything
just -f ai-lab.just status     # Check what's running
just -f ai-lab.just uninstall  # Tear it all down
```

> **On Universal Blue?** See [docs/ujust-integration.md](docs/ujust-integration.md)
> for three ways to make these commands available as native `ujust install-ai-lab`.

## Troubleshooting — can't connect to services

After install, run this to verify:

```bash
podman ps && echo "---" && curl -k https://$(systemctl status avahi-daemon --no-pager 2>/dev/null | grep -o 'running \[[^]]*\]' | sed 's/running \[\(.*\)\]/\1/'):3001 -o /dev/null -w "Open WebUI: %{http_code}\n"
```

If that returns `200`, open a browser to `https://<avahi-name>.local:3001`.

### Firewall

mDNS (`.local` name resolution) needs UDP port 5353 open:

```bash
sudo firewall-cmd --permanent --add-service=mdns --add-port=3001-3004/tcp
sudo firewall-cmd --reload
```

Verify: `avahi-resolve -n $(hostname -s).local` should return an IP, not timeout.

### Missing runtime directories

If services fail to start, create missing directories:

```bash
mkdir -p ~/.local/share/llama.cpp/models ~/.local/share/sketchlab ~/.local/share/comfyui ~/.local/share/hermes-service
```

### Podman network

The `ai-network.service` needs the podman network to exist:

```bash
podman network exists ai.network || podman network create ai.network
systemctl --user daemon-reload
systemctl --user restart ai-network.service
```

### Sketch Lab image

The installer tries in order:
1. Pull from `ghcr.io/dark5un/sketchlab:v0.5.0` (pre-built)
2. Build from `~/sketchlab.app/` if it exists
3. Clone and build from `github.com/dark5un/sketchlab.app`

If none work, build manually:

```bash
git clone https://github.com/dark5un/sketchlab.app.git
cd sketchlab.app
podman build -t localhost/sketchlab:v0.5.0 .
systemctl --user restart sketchlab.service
```

### avahi hostname conflicts

If avahi publishes a name like `host-2.local` or `host-13.local`, something
else on your LAN already claims the base name. The installer auto-detects
the published name, so configs will match. To reclaim the base name,
find the offending device and rename it, then restart avahi:

```bash
sudo systemctl restart avahi-daemon
```

Then re-run the installer to regenerate configs with the reclaimed name.

### View logs

```bash
journalctl --user -u caddy.service -n 20 --no-pager
journalctl --user -u open-webui.service -n 20 --no-pager
```

## Manual setup

### 1. Prerequisites

- **Bluefin** (or any Fedora Silverblue / ublue image)
- **Podman** (pre-installed on Bluefin)
- **NVIDIA drivers** (ublue-nvidia image, or `rpm-ostree install akmod-nvidia`)
- **nvidia-container-toolkit** (for GPU support):
  ```bash
  rpm-ostree install nvidia-container-toolkit
  systemctl reboot
  ```

### 2. Deploy

```bash
QUADLET_DIR="${HOME}/.config/containers/systemd"
CONFIG_DIR="${HOME}/.config/containers/config"
mkdir -p "$QUADLET_DIR" "$CONFIG_DIR"
cp quadlets/*.network "$QUADLET_DIR/"
cp quadlets/*.container "$QUADLET_DIR/"
cp -r config/* "$CONFIG_DIR/"
systemctl --user daemon-reload
systemctl --user enable --now ai-network.service
systemctl --user enable --now llama-cpp-main.service
systemctl --user enable --now caddy.service
systemctl --user enable --now open-webui.service
```

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

**No GPUs?** Falls back to a single CPU-based llama.cpp service.

## Sketch Lab local models

Sketch Lab's AI panel connects to any OpenAI-compatible endpoint:

1. Open Sketch Lab at `https://<avahi-name>.local:3004`
2. Click the AI button in the editor
3. Set endpoint to: `http://llama-cpp:8080` (within the network)
   or `http://127.0.0.1:11435` (from the host)
4. Select a model from the dropdown (populated from `/v1/models`)

For AI agents: the Sketch Lab skill is at
[github.com/dark5un/sketchlab.app](https://github.com/dark5un/sketchlab.app)
— see `SKILL.md` in the repo for the agent skill.

## License

Apache 2.0 — see [LICENSE](LICENSE).