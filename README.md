# AI Lab Quadlets

> **Self-hosted AI services for ONE host: Arch Linux, RTX 5090 + RTX 4070 Ti,
> rootless Podman Quadlets.** Every service starts on demand; at boot only
> the monitoring tier and the default strata variant (4070 Ti) start.

This repo packages the AI lab of the `ai` box as Podman Quadlets (declarative
container units managed by `systemd --user`). `services.json` is the single
source of truth (ports, cards, auth); `scripts/ai-lab` and the Ryoku bar widget
(`plugin/ailab`) start and stop services; `scripts/gpu-arbiter.py` keeps the
GPU rules when they do.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│ Host "ai" (Arch Linux, desktop on the iGPU)                       │
│                                                                   │
│  systemd-ai ── Podman network (containers reach each other by     │
│                container name)                                    │
│   model APIs (1143x)                    web apps (31xx)           │
│   ├── strata         0.0.0.0:11434      ├── open-webui  :3100     │
│   ├── llama-cpp-5090        :11435      ├── comfyui     :3101     │
│   ├── llama-cpp-4070ti      :11436      ├── sketchlab   :3102     │
│   ├── rizzo                 :11437      ├── hyperframes :3103     │
│   └── llama-cpp-both        :11438      ├── hermes      :3104 (opt-in)
│                                         └── dsh 127.0.0.1:3105 (opt-in)
│  RTX 5090 32 GB + RTX 4070 Ti 12 GB, shared by the rules in        │
│  docs/gpu-assignment.md. Caddy files are kept, not deployed.      │
└──────────────────────────────────────────────────────────────────┘
```

## Services

| Service (unit) | Port | Card | Auth | Description |
|---|---|---|---|---|
| `strata-5090` / `-4070ti` / `-both` | `11434` | per variant | API key | Strata (Qwen) OpenAI-compatible API, one variant at a time |
| `llama-cpp-5090` | `11435` | 5090 | API key | llama.cpp router, 262K context default |
| `llama-cpp-4070ti` | `11436` | 4070 Ti | API key | llama.cpp router, 65K context default |
| `llama-cpp-both` | `11438` | both (exclusive) | API key | llama.cpp router, layer split over both cards |
| `rizzo` | `11437` | 4070 Ti | none | Rizzo Flow, Jev-compatible System One decisions |
| `open-webui` | `3100` | - | account | chat frontend over strata + the three llama.cpp servers |
| `comfyui-5090` / `-4070ti` | `3101` | the card strata is not on | none | image generation |
| `sketchlab` | `3102` | - | none | diagramming SPA; same-origin `/v1` proxy to strata (key server-side) |
| `hyperframes` | `3103` | - | none | HyperFrames GCP Cloud Run worker (needs a GCS bucket; local renders: `scripts/hyperframes-render.sh`) |
| `hermes` (opt-in) | `3104` | - | account | containerized Hermes gateway; this host runs Hermes natively instead |
| `deepseek-harness` (opt-in) | `127.0.0.1:3105` | - | token | dsh agent runtime, host loopback only |
| `prometheus` | `127.0.0.1:3107` | - | none | metrics store; scrapes every service, OTLP receiver for Open WebUI; boot |
| `grafana` | `3106` | - | account | dashboards (provisioned from `monitoring/`), LAN with login; on demand |
| `node-exporter` | `127.0.0.1:9100` | - | none | host CPU/RAM/disk/net/temp; boot |
| `gpu-exporter` | `127.0.0.1:9835` | - | none | both cards via NVML (UUID labels, holds no VRAM); boot |
| `podman-exporter` | `127.0.0.1:9882` | - | none | container state/stats via the user podman socket; boot |
| `blackbox-exporter` | `127.0.0.1:9115` | - | none | HTTP probes of every service health URL; boot |
| `victorialogs` | `127.0.0.1:9428` | - | none | log store (30d/5GB); boot |
| `fluent-bit` | `127.0.0.1:2020` | - | none | ships px's user journal to VictoriaLogs; boot |

Containers are named `systemd-<service>` (both GPU variants of strata and
ComfyUI share `systemd-strata` / `systemd-comfyui`). Published ports bind
`0.0.0.0` (plain HTTP; trusted LAN only, never port-forwarded) except dsh.

## Install

```bash
git clone git@github.com:dark5un/ai-lab-quadlets.git ~/workspace/github.com/dark5un/ai-lab-quadlets
cd ~/workspace/github.com/dark5un/ai-lab-quadlets
./install.sh                 # configs, units, images; nothing started, nothing at boot
./install.sh --no-images     # configs + units only (fast; re-run after editing a quadlet)
```

`install.sh` is written for this host (it refuses to run unless `nvidia-smi`
lists an RTX 5090 and an RTX 4070 Ti) and is idempotent. It:

1. checks podman (rootless), nvidia-smi, python3, openssl, and hints at
   `sudo pacman -S python-huggingface-hub` if `hf` is missing;
2. writes configs to `~/.config/containers/config` (dirs 700, files 600):
   secrets via `scripts/generate-secrets.sh`, each `config/<svc>/*.example`
   copied once, and the managed lines rewritten every run: Open WebUI's four
   backends + keys and `WEBUI_URL` (`http://$(hostnamectl --static).local:3100`,
   mDNS by systemd-resolved), sketchlab's strata key, dsh's keys (if opted in);
3. runs `scripts/install-strata.sh` (strata image if missing + its 3 units);
4. renders the units (`scripts/render-units.sh`, GPU UUIDs from nvidia-smi),
   removes legacy units, masks `podman-user-wait-network-online`, reloads once;
5. creates the data dirs and links `~/.local/bin/ai-lab` + `~/.local/bin/hf-download`;
6. pulls/builds images one at a time (`scripts/build-images.sh`; `--rebuild`
   rebuilds the local ones). Sketchlab builds from
   `~/workspace/github.com/dark5un/sketchlab.app`, HyperFrames from
   `~/workspace/github.com/heygen-com/hyperframes`.

Open WebUI runs with `ENABLE_PERSISTENT_CONFIG=false` (managed line): its
env file is authoritative, so the backends and keys always come from
`service.env` and a key rotation reaches it. Settings changed in the admin UI
are not persisted and reset on the next restart; change the env file (or
`install.sh`) instead. Accounts and chats live in the `open-webui-data`
volume and are kept.

Opt-ins: `--with-deepseek-harness`, `--with-hermes`. `./uninstall.sh` stops
everything and removes units, the bar plugin and the `~/.local/bin` links;
data and configs stay.

## Usage

```bash
ai-lab status                    # every service: state, port, health
ai-lab start open-webui          # start (GPU rules applied); --dry-run shows the plan
ai-lab stop comfyui              # groups work: strata, comfyui
ai-lab strata 5090               # 5090 | 4070ti | both | off
ai-lab url sketchlab             # browser URL
```

The AI Lab bar widget (`plugin/ailab`, Ryoku QS Bar) does the same with one
click per service and a strata selector. Never `systemctl --user start` a GPU
unit directly: that bypasses the arbiter (strata's `Conflicts=` then stops
strata instead of moving it).

`scripts/reset-comfyui.sh [--dry-run] [--backup]` wipes ComfyUI's
settings/DB/caches and keeps models, inputs, outputs and custom nodes.
`scripts/rotate-secrets.sh [--yes]` rotates the Open WebUI, strata and
llama.cpp secrets and rewrites every client's copy.

### Strata: GPU variants and context sizes

Strata runs as one variant at a time, all on port 11434 with the same
container name (`systemd-strata`) and API key; a card and a context make the
variant. Past the trained 262,144 tokens, Strata's setup adds YaRN rope
scaling (x2 at 524K, x4 at 1M), fixed per engine start, so each context is its
own unit with its own setup config. The KV cache streams from RAM (32K tokens
resident in VRAM), so a bigger window costs mostly RAM.

| variant | GPU(s) | context | model |
|---|---|---|---|
| `strata-5090`, `-5090-524k`, `-5090-1m` | RTX 5090 32 GB | 256K / 524K / 1M | IQ3_S |
| `strata-4070ti`, `-4070ti-524k`, `-4070ti-1m` | RTX 4070 Ti 12 GB | 256K / 524K / 1M | IQ3_XXS |
| `strata-both` | 5090 + 4070 Ti | 256K | IQ3_XXS (layer split; slower than the 5090 alone, so no bigger contexts) |

The coder group (Qwen3.8 Coder IQ1_M on the 4070 Ti, port 11439, container
`systemd-strata-coder`) runs one variant at a time BESIDE a 5090 variant
("duo"): `strata-coder-128k` (128K, 4 batch slots), `strata-coder` (256K, 2
slots), `strata-coder-524k`, `strata-coder-1m`. It owns
the 4070 Ti: strata on that card or any other 4070 Ti service stops it.
Batch slots (`"parallel": N` in the config, Strata's docs/BATCHING.md) decode
up to N conversations together: nobody waits for a whole answer. Measured on
this box: 256K+2 costs nothing solo and beats the queue for 2 clients; 256K+4
starves the expert cache (slower than queueing); 128K+4 is the concurrency
pick (4 clients in ~7 s). 524K/1M stay at one at a time (slots there cost
6-12 GB pinned RAM each).

`./scripts/install-strata.sh` (run by install.sh) builds `localhost/strata:multi` from
`~/workspace/github.com/Niko1221/Strata` for CUDA 120 + 89 (if missing;
`--rebuild` forces it), renders the units with the GPU UUIDs and CPU pinning,
derives the 524K / 1M configs of the 4070 Ti and the coder from their 256K
ones (context + YaRN args only; identical to what setup writes), derives the
128K coder config from the 256K one (context only, no YaRN), sets the coder's
batch slots (`"parallel"`: 2 at 256K, 4 at 128K), and reloads
systemd. Only the default variant strata-4070ti starts at boot (`[Install]`);
every other variant stays on demand — switch with the AI Lab bar
widget or:

```bash
./scripts/ai-lab strata 4070ti-1m   # 5090[-524k|-1m] | 4070ti[-524k|-1m] | both | off; --dry-run previews
./scripts/ai-lab coder 128k         # 128k | 256k | 524k | 1m | off (the coder, beside a 5090 variant)
./scripts/ai-lab strata duo 5090-1m 524k   # a 5090 variant + the coder
./scripts/ai-lab strata             # prints the live variant, e.g. 5090-1m+coder-524k
```

When strata has to leave its card (a GPU service starts there, or the coder
starts), scripts/gpu-arbiter.py moves it to the other card at the same
context (5090-1m <-> 4070ti-1m); strata-both drops to the plain card variant.

Data: the model files (`~/.local/share/strata/{models,mtp,packs}`, ~86 GB) are
shared; each variant keeps its own setup in `config-<variant>/strata-<quant>.json`
(KV/context ladder, card choice AND the API key, which wins over the env
`API_KEY`). A variant with an empty config dir runs Strata's setup on its
first start from the unit's `CONTEXT`/`KV`/`GPU(S)` env; delete the json to
re-run it. Shared settings and the key live in
`~/.config/containers/config/strata/service.env` (mode 600).

Upgrading Strata (last: 6f32ec0 / engine 0.1.39 -> 6674a00 / 0.1.40.4,
2026-10-08; decode/prefill within noise of the old build, strata-both decode
+7%):

```bash
podman tag localhost/strata:multi localhost/strata:multi-<old-commit>   # rollback point
for v in 5090 4070ti both; do d=~/.local/share/strata/config-$v
  cp -p $d/strata-iq3_s.json $d/strata-iq3_s.json.<old-commit>; done
git -C ~/workspace/github.com/Niko1221/Strata pull --ff-only
./scripts/install-strata.sh --rebuild
rm ~/.local/share/strata/config-*/strata-iq3_s.json   # re-run setup: new defaults
./scripts/ai-lab strata 5090 && ./scripts/ai-lab strata 4070ti && ./scripts/ai-lab strata both
chmod 600 ~/.local/share/strata/config-*/strata-iq3_s.json   # setup writes 644
```

Re-running setup reuses the model data (no download) and keeps the API key
(setup takes it from `service.env`); it only refreshes the json's engine args.
Upstream rewrote its git history on 2026-10-06 (#1276): a clone from before
that cannot pull; move it with `git branch pre-cleanup-backup && git checkout
-B main origin/main` (done here). Rollback: retag the old image to `:multi`
and restore the saved jsons.

GPU pinning: the strata units add the CDI device by UUID
(`AddDevice=nvidia.com/gpu=GPU-…`) so nvidia-smi (which Strata's setup reads)
and CUDA see the same cards in the same order. This is safe here because the
CDI spec is `/var/run/cdi/nvidia.yaml`, regenerated every boot by
`nvidia-cdi-refresh`; a static `/etc/cdi/nvidia.yaml` can go stale when
/dev/nvidiaN minors reshuffle, which is why the other services pin with
`CUDA_VISIBLE_DEVICES=<uuid>` instead.

### GPU rules

Strata has priority: it is the only service that owns a card. `ai-lab
start|stop|toggle|strata` and the bar widget go through
`scripts/gpu-arbiter.py`, which applies:

| service | card |
|---|---|
| strata-5090 / -4070ti / -both | 5090 / 4070 Ti / both |
| llama-cpp-5090 | 5090 |
| llama-cpp-4070ti, rizzo | 4070 Ti |
| llama-cpp-both (exclusive) | both (layer split, 5090 main) |
| comfyui (`comfyui-5090` / `comfyui-4070ti`) | the card strata is NOT on (strata off: 4070 Ti) |

1. Starting a GPU service on the card strata occupies moves strata to the
   other card (strata-both drops to the other card). Strata off stays off.
2. Starting a single-card strata variant stops every other service on that
   card, except ComfyUI, which moves to the other card.
3. Starting strata-both stops every GPU service.
4. Starting llama-cpp-both (exclusive) stops every other GPU service, strata
   included; starting any other GPU service stops llama-cpp-both first.
5. Other GPU services may share a card with each other.

`ai-lab start <name> --dry-run` prints the plan. The strata units' `Conflicts=`
is only a backstop: a bare `systemctl --user start` of a conflicting unit
stops the other side instead of moving it.

Host API: `http://<host-LAN-IP>:11434/v1` (the unit publishes on `0.0.0.0`;
every request must carry the API key — from the host itself use
`http://127.0.0.1:11434/v1`). From another container on `systemd-ai`, use
`http://systemd-strata:8080/v1`; configure the key from
`~/.config/containers/config/strata/service.env` in that client. Model data is
kept under `~/.local/share/strata`.
Strata defaults to Qwen IQ3_S at a 262,144-token context for every model setup.
Monitor RAM/VRAM on first run because long-context KV cache raises memory use.

## Direct service access

After install, verify the services are up:

```bash
podman ps
LAN_IP=$(ip -4 route get 1.1.1.1 | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')
curl -sS -o /dev/null -w 'Open WebUI: %{http_code}\n' "http://${LAN_IP}:3100/"
```

### Service endpoints

Auth status mirrors the `"auth"` field in `services.json`
(`none` | `api-key` | `account` | `token`).

| Service | URL | Auth |
|---|---|---|
| Open WebUI | `http://<host-LAN-IP>:3100` | account (login required) |
| ComfyUI | `http://<host-LAN-IP>:3101` | none |
| Containerized Hermes Gateway (optional) | `http://<host-LAN-IP>:3104` | account |
| Sketch Lab | `http://<host-LAN-IP>:3102` | none (proxies Strata on `/v1/`, key server-side) |
| DeepSeek Harness (optional) | `http://127.0.0.1:3105` (loopback only) | one-time token |
| llama.cpp APIs | `http://<host-LAN-IP>:11435/v1` (5090), `:11436` (4070 Ti), `:11438` (both) | API key (`~/.config/containers/config/llama-cpp/keys.txt`) |
| Rizzo | `http://<host-LAN-IP>:11437/v1/systemone` | none |
| Strata (optional) | `http://<host-LAN-IP>:11434/v1` | API key |
| HyperFrames API | `http://<host-LAN-IP>:3103` | none |

**LAN exposure decision (deliberate):** this stack runs on a trusted home LAN.
The unauthenticated endpoints (ComfyUI, Sketch Lab, HyperFrames, Rizzo) are
intentionally reachable from the LAN for convenience; they are
never port-forwarded to the Internet. Strata (11434) and the llama.cpp servers
are likewise LAN-bound but key-gated (llama.cpp's `/health` answers without a
key). Strata: every request must carry the API key from
`~/.config/containers/config/strata/service.env`. If the trust model changes,
rebind strata to `127.0.0.1` in `services.json` + quadlets and expose it
per-device via a VPN instead.

### ComfyUI opens but cannot generate

The container serves the UI/API but the default installer does not download
checkpoint weights. Put compatible checkpoints under
`~/.local/share/comfyui/models/checkpoints/` (plus any workflow-specific VAE,
text encoder, or LoRA files in their matching `models/` subdirectories), then
refresh the model list in ComfyUI. Check backend readiness at
`http://<host-LAN-IP>:3101/system_stats`; an empty checkpoints directory
means workflows cannot run yet. The CUDA image can expose multiple NVIDIA GPUs;
its `torch.cuda` runtime selects CUDA devices, while llama.cpp has its own
per-service GPU assignment.

### Firewall

ufw is active on this host and opens only the ports that should be reachable
from other machines (today: 11434 strata, 3101 ComfyUI); everything else
answers on the host itself. Open a port per service, explicitly:

```bash
sudo ufw allow 3100/tcp                                       # LAN + tailnet
sudo ufw allow in on tailscale0 to any port 11434 proto tcp   # tailnet only
```

DeepSeek Harness stays on loopback and never needs a rule.

### Retained Caddy configuration (not installed)

The installer deliberately does not deploy or start Caddy, install mkcert, or
modify certificate trust. The source files (`quadlets/caddy.container` and
`config/caddy/`) and host Caddy configuration/data are retained for manual use.
Default app services are plain HTTP on their direct host ports; do not expose
them outside a trusted network.

### Missing runtime directories

`./install.sh --no-images` recreates every config and data dir.

### Podman network

The Podman network `systemd-ai` is created by the `ai.network` quadlet. If it's missing:

```bash
systemctl --user daemon-reload
systemctl --user restart ai-network.service
```

### DeepSeek Harness

The container is built from `containers/deepseek-harness/Containerfile`, which
packages the official `@deepseek-ai/dsh` npm package **unpatched**, started as
stock `dsh web` (no interpreter wrapper). The entrypoint rewrites the web
profile's `patchReload` from `live` to `startup`: the live watcher requires the
Cordis HMR service, which is absent in this headless composition, and dsh
crashes without the rewrite.

Preset model connections (strata, 262k context) ship as
`config/deepseek-harness/settings.yaml.example`; the installer copies it to
`~/.local/share/deepseek-harness/settings.yaml` and expects `STRATA_API_KEY` /
`LLAMA_CPP_API_KEY` in the dsh `service.env`. The llama.cpp router route is
commented out in the template: a hand-declared provider must list at least one
model or dsh refuses the entire `llm-pi-ai` settings section at boot, and the
router serves no models until GGUFs are placed in
`~/.local/share/llama.cpp/cards/<card>` (hf-download --card). Uncomment the block and list the served
model id(s) once the router has models.

The web UI's "Open configuration file" button does not work in this container
(no desktop opener inside the image); edit
`~/.local/share/deepseek-harness/settings.yaml` on the host instead — dsh
hot-reloads it.

To force a rebuild: `./scripts/build-images.sh --rebuild deepseek-harness`.

#### Loopback-only access

dsh puts a browser-trust fence on all `/api` endpoints and binds 127.0.0.1
only (upstream safety). The Quadlet runs it with `Network=host`, so that
loopback bind lands on the host loopback directly: use
`http://127.0.0.1:3105` on the host. This service is deliberately not exposed
to the LAN, and because the browser's hostname is literally `127.0.0.1`, the
stock `isLoopback` check passes with no patches or trusted-host injection.

#### Authentication (dsh ≥ 0.1.2-rc.1)

dsh requires a one-time token to set a browser cookie. The quickest way:
`./scripts/ai-lab url deepseek-harness` prints the ready-to-open URL (the bar
plugin's LAUNCH button uses the same). Or grab it from the logs:

```bash
podman logs systemd-deepseek-harness | grep "?token="
```

Then open `http://127.0.0.1:3105/?token=<token>` in your browser.

> The token in `podman logs` is sensitive: logs live in the host's journald and
> anyone with access to your user session can read them. Treat a leaked token
> like a leaked password — restart the container to mint a new one.

### Hermes Agent gateway (opt-in, not deployed here)

`quadlets/hermes.container` (image `docker.io/nousresearch/hermes-agent:latest`)
is deployed only with `./install.sh --with-hermes`; this host runs Hermes
natively (`hermes-gateway.service`). Its dashboard (`:3104`) credentials are
generated into `~/.config/containers/config/hermes-service/service.env`.

### View logs

```bash
journalctl --user -u open-webui.service -n 20 --no-pager
podman logs systemd-deepseek-harness
podman logs systemd-llama-cpp-5090
```

## GPU units (this host: RTX 5090 + RTX 4070 Ti)

This stack is tailored to one host: GPU services are named after the card
they run on, and `quadlets/*.container.in` templates carry the placeholders
`__GPU_5090_UUID__` / `__GPU_4070TI_UUID__`. `scripts/render-units.sh NAME...`
fills them from `nvidia-smi` (cards matched by name, never by index) into
`~/.config/containers/systemd/`. See `docs/gpu-assignment.md`.

| llama.cpp | port | cards | context | KV | batch / ubatch | config |
|---|---|---|---|---|---|---|
| llama-cpp-5090 | 11435 | 5090 | 262,144 | q4_0 | 1024 / 256 | `config/llama-cpp-5090/` |
| llama-cpp-4070ti | 11436 | 4070 Ti | 65,536 | q4_0 | 512 / 128 | `config/llama-cpp-4070ti/` |
| llama-cpp-both | 11438 | 5090 + 4070 Ti, layer split (exclusive) | 262,144 | q4_0 | 1024 / 256 | `config/llama-cpp-both/` |

All three share one key file (`~/.config/containers/config/llama-cpp/keys.txt`);
each serves only the models linked for it (next section).

## Models (hf-download)

The installer downloads no weights: a llama.cpp server is healthy but lists no
models until you link some.

- **Library**: the Hugging Face cache, `~/.cache/huggingface/hub` (one copy
  of every file, downloaded with `hf download`).
- **Per server**: `~/.local/share/llama.cpp/cards/<card>/<name>/<file(s)>.gguf`,
  HARDLINKS to the library files (same btrfs subvolume, so a model on two
  servers costs disk once). Each `llama-cpp-<card>` unit mounts only its own
  `cards/<card>` dir read-only at `/models`, so a server never advertises a
  model linked for another card.
- The router lists one model per subdir; the model id is the subdir name.
  Split models (`-00001-of-0000N`) keep every part side by side in that one
  subdir. The default name is the file name minus `.gguf` and the split suffix.

```bash
hf-download unsloth/Qwen3.8-27B-GGUF UD-Q4_K_XL --card 5090
hf-download bartowski/Llama-3.2-3B-Instruct-GGUF IQ4_XS --card 5090,4070ti
hf-download Qwen/Qwen2.5-3B-Instruct-GGUF 'qwen2.5-3b-instruct-fp16-*' --card both --name qwen2.5-3b-fp16
hf-download --remove Llama-3.2-3B-Instruct-IQ4_XS --card 4070ti   # unlink; the library keeps the file
hf-download --list                                                # models per server + library
```

After linking, `refresh-presets.py --card <card> --write` writes per-model
`ctx-size` overrides (the model's trained context, capped by that server's VRAM;
`both` sums the two cards) into `~/.config/containers/config/llama-cpp-<card>/presets.ini`,
and a running `llama-cpp-<card>` restarts (the router scans its dir only at
startup). `scripts/download-gguf-series.sh` does the same for a list
(`repo|filter|cards` per line, see `scripts/gguf-download-list.example`).
To delete a file from the library for good: unlink it from every card, then
`hf cache rm model/<org>/<repo>`.
Requires `hf`: `sudo pacman -S python-huggingface-hub`.

## Sketch Lab local models

Sketch Lab's AI panel works out of the box: since v0.6.0 the app's own
nginx proxies `/v1/` to Strata and injects the API key server-side (from
`config/sketchlab/service.env`), so the default endpoint is same-origin
and the default model is the loaded Strata model — no key entry, no CORS.
Since v0.6.2 nginx resolves Strata per request, so Sketch Lab starts while
Strata is off and `/v1/` answers `502` until Strata is started. Details:
`docs/sketchlab-local-models.md`.

To point it at a different OpenAI-compatible endpoint instead:

1. Open Sketch Lab at `http://<host-LAN-IP>:3102`
2. Click the AI button in the editor
3. Set the endpoint to any OpenAI-compatible server the browser can reach
   (e.g. `http://<host-LAN-IP>:11435/v1`, llama.cpp on the 5090, with its key
   from `~/.config/containers/config/llama-cpp/keys.txt`)
4. Select a model from the dropdown (populated from `/v1/models`)

Note: the `/v1/` proxy on :3102 is unauthenticated on the LAN like the
sketchlab app itself — anyone who can reach :3102 can use the Strata key.

For AI agents: the Sketch Lab repo
[github.com/dark5un/sketchlab.app](https://github.com/dark5un/sketchlab.app)
ships a zero-dependency stdio MCP server (`mcp/server.mjs`, tools
`sketchlab_icons` / `sketchlab_validate` / `sketchlab_diagram`) that
validates diagrams with the app's own parser and returns ready-to-open
`?g=` URLs; setup snippets for Hermes, Claude Code and Strata are in its
README.

## HyperFrames

HyperFrames is an HTML-to-video render engine. Two images, two purposes:

- **Local renders: `scripts/hyperframes-render.sh <composition-dir> <out.mp4>`.**
  A one-shot CLI container (`localhost/hyperframes-render:latest`, built from
  `packages/cli/src/docker/Dockerfile.render` on first use). It needs no
  service running. A 2 s 1080p composition renders in about 5 s on the CPU.
- **The `hyperframes` service on :3103** runs the
  [GCP Cloud Run adapter](https://github.com/heygen-com/hyperframes)
  (`packages/gcp-cloud-run`). It is only the worker half of a distributed
  render: `GET /healthz`, and `POST /` with `Action` = `plan` /
  `renderChunk` / `assemble`, each of which downloads from and uploads to a
  **GCS bucket**. It cannot render local files; without a bucket and Google
  credentials every action fails. Start it only if you drive it with the
  `@hyperframes/gcp-cloud-run` SDK against your own bucket.

The installer builds the service image from a hyperframes repo checkout; by
hand:

```bash
cd /path/to/hyperframes
podman build -f packages/gcp-cloud-run/Dockerfile -t localhost/hyperframes:latest .
```

## Monitoring

Prometheus + Grafana + VictoriaLogs, all rootless quadlets (plan:
~/Documents/plans/ai-lab-monitoring-plan.md). The monitoring tier is the
stack's one deliberate boot exception: Prometheus, the exporters and the
log pair enable at boot (they hold no GPU/VRAM); Grafana stays on demand
with the web apps. `ai-lab start|stop monitoring` (or the MONITORING row
in the bar plugin) controls the whole group.

- What is scraped: strata + coder (`/metrics`, bearer = the strata key),
  the llama.cpp routers (`/metrics?model=X&autoload=false` per model in
  the card dir — never autoloads), ComfyUI (the exporter node baked into
  the image), every service's health URL via blackbox, both GPUs via
  NVML, the host via node-exporter, containers via the user podman
  socket, and Open WebUI via OTLP push into Prometheus.
- Configs are GENERATED from services.json by `scripts/render-prometheus.py`
  (run by install.sh): registering a service puts it under monitoring.
  Never edit `~/.config/containers/config/{prometheus,blackbox,fluent-bit}/`
  by hand.
- Dashboards live in git under `monitoring/grafana/dashboards/` and are
  provisioned read-only: AI Lab Overview (mode timeline, both cards, RAM,
  tok/s, health grid), Strata (upstream), llama.cpp, Open WebUI, ComfyUI,
  Node Exporter Full (1860), NVIDIA (14574/25547), Podman (21559).
  Sources + revisions in monitoring/README.md.
- Logs: fluent-bit reads px's user journal (read-only) and pushes to
  VictoriaLogs (30d/5GB); Grafana queries it via the
  victoriametrics-logs-datasource plugin. Pitfalls encoded in the
  quadlet: fluent-bit must be 4.2+ (4.0 cannot read this ZSTD journal)
  and must NOT use keep-id (the journal ACL grants px, who is container
  root; keep-id maps to nobody and silently reads 0 records).
- Grafana: http://<host>:3106, admin / password from
  `~/.config/containers/config/grafana/service.env` (generate-secrets.sh).
- Monitoring never loads or keeps awake any model: llama.cpp scrapes use
  `autoload=false` and the routers set no idle timer; the GPU exporter
  holds no VRAM; strata scrape cost measured <1% of decode tok/s.

## AI Lab bar plugin

The Ryoku bar plugin (`plugin/ailab/` in this repo) shows the stack state in
the top bar: a glyph with the running/total count, and a panel listing every
service in `services.json` with start/stop toggles and health. Clicking a
service name or its LAUNCH button opens the service URL in your default
browser (with the dsh auth token appended automatically) and closes the
panel.

- Install: `ryoku plugin add plugin/ailab --bar --yes` (from the repo root).
  The authoring copy at `~/Documents/ryoku-plugins/ailab` is a symlink into
  this repo, so there is a single source of truth.
- Settings: QS Bar Settings > Community > AI Lab — running/total count badge
  and poll interval.
- Remove: `ryoku plugin remove ailab`.
- The plugin's only external commands are `systemctl --user`, `curl`
  (127.0.0.1 health checks), `python3` (registry parsing) and `xdg-open`
  (launch), declared in `manifest.json`; keep that list honest if the CLI
  grows commands.

## License

Apache 2.0 — see [LICENSE](LICENSE).
