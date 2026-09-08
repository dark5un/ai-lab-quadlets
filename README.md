# AI Lab Quadlets

> **Reproducible self-hosted AI services on Universal Blue / Bluefin / any immutable Fedora.**

This repo packages a full self-hosted AI lab as Podman Quadlets — declarative container
units managed by systemd. Everything runs rootless on the immutable host, survives
reboots, and can be rehydrated on a fresh machine with one command.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                 Host (Bluefin / Fedora)                       │
│                                                               │
│  ai.network ──── Podman network (internal)                    │
│       │                                                      │
│       ├── systemd-caddy:3001-3005  ──── HTTPS reverse proxy   │
│       │    ├─ :3001 → systemd-open-webui:8080                 │
│       │    ├─ :3002 → systemd-comfyui:8188                    │
│       │    ├─ :3003 → systemd-hermes-gateway:9119             │
│       │    ├─ :3004 → systemd-sketchlab:8080                  │
│       │    └─ :3005 → systemd-deepseek-harness:3080           │
│       │                                                      │
│       ├── systemd-llama-cpp:11435  ←─ largest GPU / iGPU     │
│       │    └─ /models:ro                                      │
│       │    └─ /presets.ini                                    │
│       │                                                      │
│       ├── systemd-open-webui:3000  ──── AI chat frontend     │
│       ├── systemd-comfyui:8188     ──── Image generation     │
│       ├── systemd-sketchlab:8080   ──── Diagram editor        │
│       ├── systemd-deepseek-harness:3080 ─ Agent runtime      │
│       ├── systemd-hermes-gateway:9119 ── AI agent gateway    │
│       └── systemd-hyperframes:3006 ──── Video render API     │
└──────────────────────────────────────────────────────────────┘
```

## Services

| Service | Status | Port | Description |
|---|---|---|---|
| **ai-network** | core | — | Podman network for all container communication |
| **systemd-llama-cpp** | core | `11435` | llama.cpp on the largest GPU (long context, big models) |
| **systemd-llama-cpp-research** | optional | `11436` | llama.cpp on the 2nd GPU (conservative settings) |
| **systemd-open-webui** | web | `3000` | AI chat frontend (OpenAI-compatible backend) |
| **systemd-caddy** | proxy | `3001-3005` | HTTPS reverse proxy, internal TLS |
| **systemd-comfyui** | image | `8188` | Stable Diffusion / AI image generation |
| **systemd-sketchlab** | diagram | `8080` | Diagramming SPA with local LLM support |
| **systemd-deepseek-harness** | agent | `3080` | Agent runtime (plugin-based, official npm) |
| **systemd-hermes-gateway** | agents | `9119` | Nous Research Hermes Agent gateway |
| **systemd-hyperframes** | video | `3006` | HTML-to-video render API (headless) |

> **Container naming:** All containers are prefixed with `systemd-` to avoid conflicts
> with distrobox/toolbox containers that may share short names (e.g. `hermes`).
>
> **Network naming:** All containers connect to the Podman network `ai.network`
> (created by `quadlets/ai.network`).

## Quick Install

```bash
# One command (requires git):
curl -fsSL https://raw.githubusercontent.com/dark5un/ai-lab-quadlets/main/install.sh | bash
```

The installer is **idempotent** — safe to re-run on an already-installed system.
It detects the actual avahi/mDNS hostname so configs work on any machine.

> **`.local` resolution preflight** — the installer stops up front if your
> `<hostname>.local` doesn't resolve through the OS (`getent`), because all
> service URLs depend on it. On Arch this needs `nss-mdns` + an nsswitch.conf
> edit; the installer prints the exact fix. Use `--skip-resolve-check` to
> install anyway:
> ```bash
> ./install.sh --skip-resolve-check
> ```
> Other flags: `--force-rebuild`, `--reset-comfyui`, `--dry-run`, `--backup`,
> `--skip-hermes` (don't start the containerized Hermes gateway when you run
> Hermes natively on the host).

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

After install, verify the services are up:

```bash
podman ps
curl -sk https://$(avahi-resolve -n "$(hostname -s).local" 2>/dev/null | awk '{print $2}'):3001 -o /dev/null -w "Open WebUI: %{http_code}\n"
```

If that returns `200`, open a browser to `https://<avahi-name>.local:3001`.

### Service endpoints

| Service | URL |
|---|---|
| Open WebUI | `https://<avahi-name>.local:3001` |
| ComfyUI | `https://<avahi-name>.local:3002` |
| Hermes Agent | `https://<avahi-name>.local:3003` |
| Sketch Lab | `https://<avahi-name>.local:3004` |
| DeepSeek Harness | `https://<avahi-name>.local:3005` |
| HyperFrames API | `http://127.0.0.1:3006` (headless, localhost only) |

### Firewall

mDNS (`.local` name resolution) needs UDP port 5353 open:

```bash
sudo firewall-cmd --permanent --add-service=mdns --add-port=3001-3005/tcp
sudo firewall-cmd --reload
```

Verify: `avahi-resolve -n $(hostname -s).local` should return an IP, not timeout.

### Local TLS certificates (mkcert)

All service URLs (`https://<hostname>.local:3001-3005`) are served over HTTPS by
Caddy. The installer uses **mkcert** to issue a locally-trusted certificate if
available:

- It creates a CA trusted in the system store (`mkcert -install`) and issues a
  long-lived (~2y3m) certificate for your `.local` hostname.
- The CA and certs live **on the host** in
  `~/.config/containers/config/caddy/certs/`, bind-mounted read-only into the
  caddy container. Because they live on the host (not inside the ephemeral
  `caddy-data` volume), they survive container rebuilds, and you **don't** get
  Caddy's default 12-hour leaf-cert churn or its Chromium "expired certificate"
  quirk.

If `mkcert` is not installed, the installer falls back to Caddy's `tls internal`
CA and prints the commands to trust that CA root manually. To force the mkcert
path on an existing install, ensure `mkcert` is present, re-run the installer,
and (if the CA couldn't be auto-trusted) run `sudo mkcert -install` once.

### Missing runtime directories

If services fail to start, create missing directories:

```bash
mkdir -p ~/.local/share/llama.cpp/models ~/.local/share/sketchlab \
         ~/.local/share/comfyui ~/.local/share/hermes-service \
         ~/.local/share/deepseek-harness
```

### Podman network

The `ai.network` network is created by the quadlet (`ai.network`). If it's missing:

```bash
podman network exists ai.network || podman network create ai.network
systemctl --user daemon-reload
systemctl --user restart ai-network.service
```

### DeepSeek Harness

The container is built from `containers/deepseek-harness/Containerfile`, which
packages the official `@deepseek-ai/dsh` npm package. To force a rebuild:

```bash
podman rmi -f localhost/deepseek-harness:0.1.2-rc.1
curl -fsSL https://raw.githubusercontent.com/dark5un/ai-lab-quadlets/main/install.sh | bash -s -- --force-rebuild
```

#### Reverse proxy (Caddy) — the 403 fix

dsh puts a browser-trust fence on all `/api` endpoints. Accessing through Caddy
requires `DSH_TRUSTED_HOSTS` set to the external hostname:port. This is configured
in `config/deepseek-harness/service.env`.

The client-side `isLoopback` check is also patched via
`containers/deepseek-harness/patch-client-loopback.mjs` — it injects the trusted
hostnames into the SPA so the Settings and Models pages work remotely.

#### Authentication (dsh ≥ 0.1.2-rc.1)

dsh requires a one-time token to set a browser cookie. Get the token from:

```bash
podman --remote logs systemd-deepseek-harness | grep "?token="
```

Then open `https://<avahi-name>.local:3005/?token=<token>` in your browser.

### Hermes Agent gateway

Hermes runs in the `hermes` systemd quadlet (`quadlets/hermes.container`, image
`docker.io/nousresearch/hermes-agent:latest`) and is started and managed like the
other services. It connects to `systemd-llama-cpp` for local model serving and the
dashboard is reachable at `https://<avahi-name>.local:3003`.

Dashboard credentials are read from
`config/hermes-service/service.env` (generated by `scripts/generate-secrets.sh`).

### View logs

```bash
journalctl --user -u caddy.service -n 20 --no-pager
journalctl --user -u open-webui.service -n 20 --no-pager
podman --remote logs deepseek-harness
podman --remote logs systemd-hermes-gateway
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
- **mkcert** (recommended for locally-trusted TLS; optional — the installer
  falls back to Caddy's internal CA if absent):
  - Arch: `sudo pacman -S mkcert` (auto-installed by the installer)
  - macOS: `brew install mkcert`
  - Linux: see https://github.com/FiloSottile/mkcert#installation

### 2. Deploy

```bash
QUADLET_DIR="${HOME}/.config/containers/systemd"
CONFIG_DIR="${HOME}/.config/containers/config"
mkdir -p "$QUADLET_DIR" "$CONFIG_DIR"
# Copy quadlets and the config tree as-is:
cp quadlets/*.network quadlets/*.container "$QUADLET_DIR/"
cp -r config/* "$CONFIG_DIR/"
# Metadata service.env files: generate-secrets.sh fills in the env files from
# their .example templates, and the dsh quadlet additionally needs a service.env
# (install.sh generates one automatically):
bash scripts/generate-secrets.sh
mkdir -p "$CONFIG_DIR/deepseek-harness"
printf 'DSH_PORT=3080\nDSH_INTERNAL_PORT=3081\nDSH_TRUSTED_HOSTS=%s.local:3005\nDSH_ALLOW_REMOTE_CONFIGURATION=true\n' "$(hostname -s)" \
  > "$CONFIG_DIR/deepseek-harness/service.env"
systemctl --user daemon-reload
# Start in dependency order (generated units are quadlet-managed — use
# `restart`, not `enable --now`, or systemd reports "transient or generated"):
systemctl --user restart ai-network.service
sleep 1
systemctl --user restart llama-cpp-main.service
systemctl --user restart open-webui.service
systemctl --user restart comfyui.service
systemctl --user restart caddy.service
systemctl --user restart sketchlab.service
systemctl --user restart deepseek-harness.service
systemctl --user restart hermes.service      # omit if running Hermes natively
systemctl --user restart hyperframes.service
```

> Prefer the installer (`./install.sh` or `just -f ai-lab.just install`) — it
> handles the `.local` resolution preflight, mkcert TLS, the dsh/hermes
> metadata env files, and the start ordering above automatically.

### iGPU/Vulkan acceleration (non-NVIDIA machines)

On machines without NVIDIA GPUs, the installer checks for `/dev/dri` — the
presence of an integrated GPU (iGPU) or any other DRM device. If found:

- The **llama.cpp** quadlet is switched to the `:server-vulkan` image
- The host GPU is passed through to the container via `AddDevice=/dev/dri`
- Offload is enabled via `LLAMA_ARG_N_GPU_LAYERS=99` in the service.env

This provides significant speedup on modern laptop iGPUs. For example, on a
**Ryzen AI 9 HX 370** (Radeon 890M) running a 27B model, tok/s goes from
~3 (CPU-only) to **~15-30** (Vulkan iGPU offload), depending on quantization.

If no `/dev/dri` is present (e.g. headless server), the plain CPU image is
used and no device passthrough is configured. The `:server-vulkan` image
also handles this gracefully — it falls back to CPU-only if no Vulkan device
is available at runtime.

**Note:** ComfyUI uses PyTorch, not Vulkan, so its CPU variant remains
CPU-only even when an iGPU is present. For ComfyUI on AMD iGPUs, ROCm
support for `gfx1150` (Radeon 890M) is experimental in ROCm 7.10.0 but
requires Ubuntu 24.04 with a specific kernel — not practical on Bluefin.

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

## Downloading models (hf-download)

The installer puts `hf-download` in `~/.local/bin/` — a simple wrapper around
the HuggingFace CLI that downloads a model and registers it with llama.cpp:

```bash
hf-download unsloth/Qwen3.8-27B-GGUF UD-IQ1_M
```

- arg1 — HuggingFace repo ID (e.g. `unsloth/Qwen3.8-27B-GGUF`)
- arg2 (optional) — quantization or filename filter (e.g. `UD-IQ1_M`, `*IQ4_XS.gguf`)

It downloads to `~/.local/share/llama.cpp/models/` and appends the model
section to `~/.config/containers/config/llama.cpp/presets.ini`, then restarts
llama-cpp-main. Requires `hf` (the installer tries brew, then pip,
then standalone installer, and tells you what's missing).

To place files manually instead, drop GGUF files in
`~/.local/share/llama.cpp/models/` and add a section to the presets.ini.

## Sketch Lab local models

Sketch Lab's AI panel connects to any OpenAI-compatible endpoint:

1. Open Sketch Lab at `https://<avahi-name>.local:3004`
2. Click the AI button in the editor
3. Set endpoint to: `http://systemd-llama-cpp:8080` (within the network)
   or `http://127.0.0.1:11435` (from the host)
4. Select a model from the dropdown (populated from `/v1/models`)

For AI agents: the Sketch Lab skill is at
[github.com/dark5un/sketchlab.app](https://github.com/dark5un/sketchlab.app)
— see `SKILL.md` in the repo for the agent skill.

## HyperFrames

HyperFrames is an HTML-to-video render engine. The quadlet runs the
[GCP Cloud Run server](https://github.com/heygen-com/hyperframes) image,
which provides a headless render API on `http://127.0.0.1:3006`. The image is
built automatically by the installer from a hyperframes repo checkout; if you build
it manually:

```bash
cd /path/to/hyperframes
podman build -f packages/gcp-cloud-run/Dockerfile -t localhost/hyperframes:latest .
```

The `scripts/hyperframes-render.sh` script provides a one-shot render helper.

## License

Apache 2.0 — see [LICENSE](LICENSE).
