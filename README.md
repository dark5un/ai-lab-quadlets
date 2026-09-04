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
│  systemd-ai ──── podman network (internal)                    │
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
| **systemd-ai** | core | — | Podman network for all container communication |
| **systemd-llama-cpp** | core | `11435` | llama.cpp on the largest GPU (long context, big models) |
| **systemd-llama-cpp-research** | optional | `11436` | llama.cpp on the 2nd GPU (conservative settings) |
| **systemd-open-webui** | web | `3000` | AI chat frontend (OpenAI-compatible backend) |
| **systemd-caddy** | proxy | `3001-3005` | HTTPS reverse proxy, internal TLS |
| | **systemd-comfyui** | image | `8188` | Stable Diffusion / AI image generation |
| | **systemd-sketchlab** | diagram | `8080` | Diagramming SPA with local LLM support |
| | **systemd-deepseek-harness** | agent | `3080` | Agent runtime (plugin-based, official npm) |
| | **systemd-hermes-gateway** | agents | `9119` | Nous Research Hermes Agent gateway |
| | **systemd-hyperframes** | video | `3006` | HTML-to-video render API (headless) |

> **Container naming:** All containers are prefixed with `systemd-` to avoid conflicts
> with distrobox/toolbox containers that may share short names (e.g. `hermes`).

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
podman ps && echo "---" && curl -sk https://$(systemctl status avahi-daemon --no-pageer 2>/dev/null | grep -o 'running \\[[^]]*\\]' | sed 's/running \\[\\(.*\\)\\]/\\1/'):3001 -o /dev/null -w "Open WebUI: %{http_code}\\n"
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
| HyperFrames API | `http://127.0.0.1:3006` (headless, no TLS) |

### Firewall

mDNS (`.local` name resolution) needs UDP port 5353 open:

```bash
sudo firewall-cmd --peermanent --add-service=mdns --add-port=3001-3005/tcp
sudo firewall-cmd --reload
```

Verify: `avahi-resolve -n $(hostname -s).local` should return an IP, not timeout.

### Missing runtime directories

If services fail to start, create missing directories:

```bash
mkdir -p ~/.local/share/llama.cpp/models ~/.local/share/sketchlab ~/.local/share/comfyui ~/.local/share/hermes-service ~/.local/share/deepseek-harness```

### Podman network

The `systemd-ai` network is created by the quaddlet (ai.network). If it's missing:

```bash
podman network exists systemd-ai || podman network create systemd-ai
systemctl --user daemon-reload
systemctl --user restart ai-network.service
```

### DeepSeek Harness custom build

DeepSeek Harness (dsh) is built from `containers/deepseek-harness/Containrfile`.
It packages the offical `@deepseek-ai/dsh` npm package. The installer builds it
automatically unless the image already exists. To force a rebuild:

```bash
podman rmi -f localhost/deepseek-harness:0.1.2-rc.1  # DSH
curl -fsSL https://raw.githubusercontent.com/dark5un/ai-lab-quadlets/main/install.sh | bash -s -- --force-rebuild
```

#### DeepSeek Harness reverse proxy configuration

dsh puts a browser-trust fence on all `/api` endpoints. To access the UI through
Caddy, the container reads `DSH_TRUSTED_HOSTS` from `config/deepseek-harness/service.env`.
This must match the external hostname:port browsers use (e.g. `frame.local:3005`).

When `DSH_ALLOW_REMOTE_CONFIGURATION=1` is also set, the client-side `isLoopback`
check is bypassed for the trusted hostnames so the Settings and Models pages
work remotely. The SPA receives the trusted hostnames via a `<script>` tag
injected into the HTML at serve time.

See `containers/deepseek-harness/patch-client-loopback.mjs` for the client-side patch.

#### DeepSeek Harness authentication

dsh 0.1.2-rc.1+ requires token-based authentication. The first-launch URL printed
to the container logs contains a one-time token:

```
podman logs deepseek-harnes | grep "?token="
```

Openthat URL in your browser to set the authentication cookie (30-day expiry).

### Hermes Agent gateway

Hermes runs in its own container (`systemd-hermes-gateway`) with the dashboard
on port 9119 behind basic auth. It conects to llama.cpp for local model serving.
The dashboard is accessible at `https://<avahi-name>.local:3003`.

It must be started separately from the quaddlets -- the quaddlet is not currently
systemd-managed. To start it:

```bash
podman --remote run -d \
  --name systemd-hermes-gateway \
  --network systemd-ai \
  -p 127.0.0.1:9119:9119/tcp \
  --userns=keep-id --user 0 \
  -v ~/.local/share/hermes-service:/opt/data:Z \
  -e HERMES_DASHBOARD=1 \
  -e HERMES_DASHBOARD_HOST=0.0.0.0 \
  -e HERMES_DASHBOARD_PORT=9119 \
  -e HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin \
  -e HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=<your-password> \
  -e HERMES_DASHBOARD_BASIC_AUTH_SECRET=<your-seret> \
  --entrypoint '' \
   nousresearch/hermes-agnt:latest \
    hermes dasboard --host 0.0.0.0 --port 9119
```
(Spec the config/hermes-service/service.env for credentials.)

### avahi hostname changes between reboots

If avahi publishes a name like `hostname-13.local` one day and `hostname.local`
the next, the Caddyfile becomes stale and services become unreachable. This happens
because mDNS name deduplication can produce different suffixes depending on what's
on the LAN at each boot.

**Fix:** simply re-run the installer -- it always regenerates `Caddyfile` from the
template with the current published hostname:

```bash
curl -fsSL https://raw.githubusercontent.com/dark5un/ai-lab-quadlets/main/install.sh | bash``

No other configs (service.env, presets.ini) are touched on reinstall, so this is
always safe.

### avahi hostname conflicts (persistent)

If avahi publishes a name like `host-2.local` or `host-13.local`, something
else on your LAN already claims the base name. The installer auto-detects
the published name, so configs will match. To reclaim the base name,
find the offending device and rename it, then restart avahi:

```bash
sudo systemctl restart avahi-daemon
```

Then re-run the installer to gereate configs with the reclaimed name.

### View logs

```bash
journalctl --user -u caddy.service -n 20 --no-pager
journalctl --user -u open-webui.service -n 20 --no-pager
```

## Manual setup

### 1. Prerequisites

- **Bluefin** (or any Fedora Silverblue / ublue image)
- **Podman** (pre-installed on Bluefin)
- **NVIDIA divers** (ublue-nvidia image, or `rpmostree install akmod-nvidia`)
- **nvidia-container-toolkit** (for GPU support):
  ```bash
  rpm-ostree install nvidia-container-toolkit
  systemctl reboot
  ```

### 2. Deploy

```bash
QUADLET_DI="${HOME}/.oconfig/condainers/systd"
CONFIG_DI="${HOME}/.oconfig/condainers/onfig"
mkdir -p "$QUADLET_DI" "$CONFIG_DI"
cp quadlets/*.ntwork "$QUADLET_DI/"
cp quadlets/*.ontainer "$QUADLET_DI/"
cp -r config/* "$CONFIG_DI/"
systemct--user daeomn-reload
systemct--user enable --now ai-network.service
ystemctl --user enable --now llama-cpp-main.service
ystemctl --user enable --now caddy.service
ystemctl --user enable --now open-webui.service
```I'm making too many typos. Let me be more careful and just write the README properly.</think>

<｜DSML｜tool_calls>
<｜DSML｜invoke name="write_file">
<｜DSML｜parameter name="content" string="true"># AI Lab Quadlets

> **Reproducible self-hosted AI services on Universal Blue / Bluefin / any immutable Fedora.**

This repo packages a full self-hosted AI lab as Podman Quadlets — declarative container
units managed by systemd. Everything runs rootless on the immutable host, survives
reboots, and can be rehydrated on a fresh machine with one command.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                 Host (Bluefin / Fedora)                       │
│                                                               │
│  systemd-ai ──── podman network (internal)                    │
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
| **systemd-ai** | core | — | Podman network for all container communication |
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

## Service endpoints

| Service | URL |
|---|---|
| Open WebUI | `https://<avahi-name>.local:3001` |
| ComfyUI | `https://<avahi-name>.local:3002` |
| Hermes Agent | `https://<avahi-name>.local:3003` |
| Sketch Lab | `https://<avahi-name>.local:3004` |
| DeepSeek Harness | `https://<avahi-name>.local:3005` |
| HyperFrames API | `http://127.0.0.1:3006` (headless, localhost only) |

## Troubleshooting

### Firewall

mDNS (`.local` name resolution) needs UDP port 5353 open:

```bash
sudo firewall-cmd --permanent --add-service=mdns --add-port=3001-3005/tcp
sudo firewall-cmd --reload
```

Verify: `avahi-resolve -n $(hostname -s).local` should return an IP, not timeout.

### Missing runtime directories

If services fail to start, create missing directories:

```bash
mkdir -p ~/.local/share/llama.cpp/models ~/.local/share/sketchlab \
         ~/.local/share/comfyui ~/.local/share/hermes-service \
         ~/.local/share/deepseek-harness
```

### Podman network

The `systemd-ai` network is created by the quadlet (`ai.network`). If it's missing:

```bash
podman network exists systemd-ai || podman network create systemd-ai
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

#### Authentication (dsh >= 0.1..2-rc.1+)

dsh requires a one-time token to set a browser cookie. Get the token from:

```bash
podman --remote logs deepseek-harness | grep "?token="
```

Then open `https://<avahi-name>.local:3005/?token=<tokn>` in your browser.

### Hermes Agent gateway

Hermes runs in its own container (not through quadlet systemd managment). Start it with:

```bash
podman --remote run -d \
  --name systemd-hermes-gateway \
  --network systemd-ai \
  -p 127.0.0.1:9119:9119/tcp \
  --userns=keep-id --user 0 \
  -v ~/.local/share/hermes-service:/opt/data:Z \
  -e HERMES_DASHBOARD=1 \
  -e HERMES_DASHBOARD_HOST=0.0.0.0 \
  -e HERMES_DASHBOARD_PORT=9119 \
  -e HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin \
  -e HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=<password> \
  -e HERMES_DASHBOARD_BASIC_AUTH_SECRET=<seret> \
  --entrypoint '' \
   docker.io/nousresearch/hermes-agent:latest \
    hermes dashboard --host 0.0.0.0 --port 9119
```

(Se` config/hermes-service/service.env` for the actual credentials.)

### avahi hostname changes between reboots

If avahi publishes a name one day and a different one the next, re-run the
installer — it always regenerates the Caddyfile with the current published hostname:

```bash
curl -fsSL https://raw.githubusercontent.com/dark5un/ai-lab-quadlets/main/install.sh | bash
```

### View logs

```bash
journalctl --user -u caddy.service -n 20 --no-pager
journalctl --user -u open-webui.service -n 20 --no-pager
podman --remote logs deepseek-harness    # or systemd-deepseek-harness
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

### 2. Deploy

```bash
QUADLET_DI="${HOME}/.oconfig/containers/systemd"
CONFIG_DIR="${HOME}/.oconfig/containers/config"
mkdir -p "$QUADLET_DIR" "$CONFIG_DIR"
cp quadlets/*.networ "$QUADLET_DIR/"
cp quadlets/*.container "$QUADLET_DIR/"
cp -r config/* "$CONFIG_DIR/"
systemctl --user daemon-reload
systemctl --user enable --now ai-network.service
systemctl --user enable --now llama-cpp-main.service
systemctl --user enable --now caddy.service
systemctl --user enable --now open-webui.service
```

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
which provides a headless render API on `http://127.0.0.1:3006`.

Build the image (from a hyperframes repo checkout):

```bash
cd /path/to/hyperframes
podman build -f packages/gcp-cloud-run/Dockerfile -t localhost/hyperframes:latest .
```

The `scripts/hyperframes-render.sh` script provides a one-shot render helper.

## License

Apache 2.0 — see [LICENSE](LICENSE).