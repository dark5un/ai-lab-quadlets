# VS Code Server quadlet — build plan (v0.5, 2026-11-03)

v0.5: the box no longer mounts `~/workspace` (syncthing-synced; host clones
stay there for host use). New workspace dir **`~/.workspaces/vscode`**,
mounted at the SAME path inside — everything the same-path distrobox trick
provides still holds for work started in the box.

v0.4: ports re-slotted against the live registry — host port **3113**
(3100-3112 are consumed: embeddings 3109, openviking 3110, honcho-api 3111,
dufs 3112) and tailscale serve **https :8443** (443 `/` root belongs to
dufs; 3113/8443 verified unused in repo, quadlets and live listeners).
v0.3: access path changed to **Tailscale Serve** (host tailscaled verified
active; serve config already live) — tailnet-only TLS front, loopback publish.
v0.2: guest package set fixed (base-devel, mise, neovim added), px login
shell = fish, and host GPU access designed in (see §2 "GPU visibility" —
the arbiter trap).

Goal: a persistent, Arch-based dev box that serves the real VS Code editor,
runs as a rootless quadlet (`systemd-vscode`), and can drive the HOST's
Podman exactly like distrobox does.

Decisions verified against the live box: host `px` is uid/gid 1000, rootless
`podman.socket` is enabled+active (`/run/user/1000/podman/podman.sock`),
Podman 6.1.4 (Quadlet `UserNS=keep-id` already used stack-wide), and the
port plan doc lagged the registry: 31xx is consumed through **3112**, so
vscode takes **3113** (verified: no quadlet, registry entry, or listener
uses 3113 or 8443).

---

## 1. Which "VS Code server" (research summary)

Three candidates, all runnable in a container:

| option | what it is | extensions | auth | verdict |
|---|---|---|---|---|
| **MS VS Code Server** (`code serve-web`) | official, standalone CLI binary (`cli-linux-x64` tarball) that serves the genuine VS Code web UI; GA since 1.82 | full MS marketplace (Pylance, Copilot, etc.) | connection token (`--connection-token`) | **CHOSEN** — genuine product, no build toolchain in the image, marketplace matters for real coding |
| code-server (coder) | OSS browser VS Code; AUR package builds from source (slow in a Containerfile); standalone tarball exists | Open VSX only — no Copilot/Pylance/Live Share (MS terms) | password | fallback if you ever want zero-Microsoft |
| `code tunnel` | same official CLI, outbound-only tunnel to Microsoft's relay; connect from desktop VS Code / vscode.dev | full marketplace | GitHub/MS account | add later if you want desktop-client sessions; same image supports it (`code tunnel`) |

Licensing note (verified): `serve-web` prints the VS Code Server License
(aka.ms/vscode-server-license) at first start and requires
`--accept-server-license-terms`; the terms tie server use to a licensed copy
of VS Code — fine for your personal use. `--disable-telemetry` is supported.

Pin the CLI by commit:
`https://update.code.visualstudio.com/commit:<SHA>/cli-linux-x64/stable`
verified live 2026-11-03: `latest` = commit
`261c84cb1eddf11235f9e2c921425e9663fbe556` (URL 302s to
`vscode_cli_linux_x64_cli.tar.gz`). The CLI downloads the matching VS Code
Server component on first start into `~/.vscode-cli`/`~/.vscode-server` —
both land in the persisted home, so this is a one-time cost.

## 2. Architecture

- **Image**: `FROM docker.io/library/archlinux@sha256:42217d5f09e11d3fe7ad3b309b7fde891d458464dab5d674e629073765610427`
  (latest amd64 digest, verified 2026-11-03; bump deliberately with `pacman -Syu` in a rebuild).
- **Identity / sudo**: `UserNS=keep-id` maps host uid/gid 1000 → container
  uid/gid 1000; image defines group/user `px` with exactly 1000:1000 and adds
  px to `wheel` with a `NOPASSWD` sudoers drop-in. `sudo` inside is root
  *within the userns* — enough for `sudo pacman -S` and file ownership games,
  cannot touch the host beyond the mounted paths. This is the distrobox model.
- **Persistent home**: host `~/.homes/vscode/px` → `/home/px`. Holds dotfiles,
  extensions, `~/.vscode-server`, secrets you generate inside. Survives image
  rebuilds.
- **Workspace (v0.5, remapped 2026-11-04)**: host `~/.workspaces/vscode`
  → **`~/workspace`** inside the container, matching the
  `~/workspace/<git-host>/<owner>/<repo>` clone convention in the box's own
  shell. Still deliberately NOT the host's syncthing-synced `~/workspace`
  tree (box work kept separate). Consequence: bind-mount SOURCE paths from
  the box go to the host daemon, so to mount box-workspace files reference
  the HOST path `$HOME/.workspaces/vscode/...`, not the container's
  `~/workspace/...`.
- **Host Podman (distrobox-like)**:
  - mount `%t/podman/podman.sock` → `/run/user/1000/podman/podman.sock`,
  - `Environment=XDG_RUNTIME_DIR=/run/user/1000` so the guest `podman` CLI
    finds the socket by default,
  - install the Arch `podman` package in the guest — client-only; every
    `podman`/`docker`-API call there executes against the HOST daemon/storage.
  - Security stance (same as distrobox): the socket grants full control of
    the host's rootless Podman. Deliberate; it is the feature you asked for.
- **Network**: `ai.network` with `Wants=/After= ai-network.service` (policy),
  no `network-online.target`, `SuccessExitStatus=143`, **no `[Install]`** —
  on-demand like every web app tier: `systemctl --user start vscode.service`.
- **GPU visibility (the arbiter trap — design decision)**: registering a
  `gpu` field in `services.json` puts the service under
  `scripts/gpu-arbiter.py`'s rules: **every start would move or stop strata**
  (rule R1) for a box that does not even use the cards. So vscode must NOT
  carry a registry `gpu`/`exclusive` field. Instead it follows the
  `gpu-exporter` precedent: `AddDevice=nvidia.com/gpu=all` in the quadlet
  (driver libs + `nvidia-smi` injected via the CDI spec
  `/var/run/cdi/nvidia.yaml` — verified present, regenerated each boot by
  `nvidia-cdi-refresh`), **no** `CUDA_VISIBLE_DEVICES` in the unit (both
  cards visible; pin per process with `CUDA_VISIBLE_DEVICES=<UUID>` when
  GPU work actually happens), `SecurityLabelDisable=true` (convention of
  every GPU unit here). This requires a one-line policy-test change: add
  `"vscode"` to `GPU_DEVICE_OK` in `tests/test-quadlet-policy.sh` — the
  test's exception branch (`line ~81`) accepts exactly `AddDevice=all` +
  no `CUDA_VISIBLE_DEVICES` for whitelisted units.
- **Exposure**: `PublishPort=127.0.0.1:3113:8000/tcp` (31xx web-app family;
  loopback-only — the tailscale serve listener is the only remote door; the
  browser client itself is what speaks to the server, one port).
- **Access path: Tailscale Serve (primary; verified live on this host)**:
  tailscaled 1.104.4 is installed and active, `tailscale serve` is already
  configured (an existing `/` route on this node — we add a separate
  HTTPS-port listener and do not touch it). Serve gives us, for free,
  exactly what VS Code requires for non-localhost origins: **valid TLS**
  (ts.net cert, no cert management) and a **tailnet-only** reach surface —
  nothing new opens on the LAN. Command:

      tailscale serve --https=8443 http://127.0.0.1:3113

  The quadlet keeps `PublishPort=127.0.0.1:3113:8000/tcp` (loopback):
  tailscaled runs on the host, so it proxies from host loopback into the
  published port. No base-path tricks needed — a dedicated HTTPS port keeps
  serve-web at the URL root, which is the path of least breakage for its
  WebSocket traffic. From any tailnet device (browser or desktop VS Code
  via the same URL): `https://ai.<TAILNET>.ts.net:8443`.
  **Redaction rule (repo is PUBLIC — verified via gh):** never commit the
  real ts.net FQDN, tailnet name, or the 100.x host IP into this repo; the
  tailscale serve config itself lives in tailscaled's state on the host,
  not in git.
- **Fallback access (no tailnet)**: `ssh -L 8000:127.0.0.1:3113 ai` →
  `http://localhost:8000` (localhost origin satisfies the TLS rule).
  Caddy LAN-front stays deferred; tailscale supersedes its motivation.
  The connection token remains on regardless — defense in depth.

## 3. Files to add (repo conventions)

```
containers/vscode/Containerfile
containers/vscode/entrypoint.sh
quadlets/vscode.container
config/vscode/service.env.example        # real file generated on-target by the secrets flow
services.json                            # registry entry
scripts/build-images.sh                  # add vscode to DEFAULT
tests/test-quadlet-policy.sh             # GPU_DEVICE_OK += "vscode"
docs/port-plan.md                        # row: vscode 3113
```

### 3.1 `containers/vscode/Containerfile`

```dockerfile
# VS Code Server dev box (Arch) — image
#
# Build:
#   podman build -t localhost/vscode:<VSCODE_VERSION> -f containers/vscode/Containerfile containers/vscode/
#
# Official VS Code Server CLI pinned by commit. Update deliberately:
#   resolve https://update.code.visualstudio.com/latest/cli-linux-x64/stable, read commit from URL.
#
# uid/gid 1000 MUST match host px; quadlet runs with UserNS=keep-id.

# syntax=docker/dockerfile:1.7
FROM docker.io/library/archlinux@sha256:42217d5f09e11d3fe7ad3b309b7fde891d458464dab5d674e629073765610427

ARG VSCODE_COMMIT=261c84cb1eddf11235f9e2c921425e9663fbe556

# Full -Syu first (digest-pinned base: never a partial upgrade).
# Starter package set is deliberately small; px installs the rest with sudo.
# mise is pacman-managed here exactly like on the host (2026.10.x).
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm --needed \
      base-devel bash curl ca-certificates fish git jq mise neovim \
      openssh fd fzf procps-ng iproute2 ripgrep which \
      sudo podman \
      unzip zip tar gzip xz && \
    pacman -Sc --noconfirm

# px = 1000:1000 (keep-id maps it to host px); fish is the login shell;
# wheel + NOPASSWD = distrobox-style sudo. The fish pacman hook registers
# /usr/bin/fish in /etc/shells, so useradd -s accepts it.
RUN groupadd -g 1000 px && \
    useradd -m -u 1000 -g 1000 -s /usr/bin/fish -G wheel px && \
    printf 'px ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/px && \
    chmod 0440 /etc/sudoers.d/px && \
    visudo -c

# VS Code Server CLI (single static-ish binary; glibc base, NOT the alpine build)
RUN curl -fL "https://update.code.visualstudio.com/commit:${VSCODE_COMMIT}/cli-linux-x64/stable" \
      -o /tmp/vscode-cli.tar.gz && \
    tar xzf /tmp/vscode-cli.tar.gz -C /usr/local/bin && \
    rm /tmp/vscode-cli.tar.gz && \
    /usr/local/bin/code --version

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

USER px:px
WORKDIR /home/px
EXPOSE 8000
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

### 3.2 `containers/vscode/entrypoint.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

: "${VSCODE_CONNECTION_TOKEN:?set via EnvironmentFile (config/vscode/service.env)}"
# guest podman client -> host daemon (socket mounted by quadlet)
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"

exec code serve-web \
  --host 0.0.0.0 --port 8000 \
  --connection-token "$VSCODE_CONNECTION_TOKEN" \
  --accept-server-license-terms \
  --disable-telemetry
```

### 3.3 `quadlets/vscode.container`

```ini
[Unit]
Description=VS Code Server - Arch dev box (serve-web), host-podman aware
Wants=ai-network.service
After=ai-network.service

[Container]
ContainerName=systemd-vscode
Image=localhost/vscode:<VSCODE_VERSION>
Network=ai.network
UserNS=keep-id

# GPU: full card visibility via CDI (nvidia-smi/CUDA work inside) but NO
# registry "gpu" field -> the arbiter never treats this as a card claim.
# Both cards visible; pin per process with CUDA_VISIBLE_DEVICES when needed.
# Matches the test's GPU_DEVICE_OK exception (add "vscode" to the set).
AddDevice=nvidia.com/gpu=all
SecurityLabelDisable=true

EnvironmentFile=%h/.config/containers/config/vscode/service.env

# persistent home (extensions, .vscode-server, dotfiles)
Volume=%h/.homes/vscode/px:/home/px:Z
# box workspace -> ~/workspace inside the container (host path for bind sources!)
Volume=%h/.workspaces/vscode:/home/px/workspace:Z
# distrobox-style host Podman API
Volume=%t/podman/podman.sock:/run/user/1000/podman/podman.sock

Environment=XDG_RUNTIME_DIR=/run/user/1000
PublishPort=127.0.0.1:3113:8000/tcp

[Service]
# A container killed by the stop signal exits 143; that is a clean stop.
SuccessExitStatus=143
Restart=on-failure
RestartSec=10
# first start downloads the VS Code Server component into the home
TimeoutStartSec=900
TimeoutStopSec=120
```

Deliberately **no `[Install]`** — `test-quadlet-policy.sh`'s allowlist is
monitoring/files tiers only; vscode joins the on-demand web-app tier
(`boot: false` in the registry).

### 3.4 `config/vscode/service.env.example`

```
# generated on-target by the secrets flow (same pattern as sketchlab/hermes)
VSCODE_CONNECTION_TOKEN=CHANGE-ME
```

### 3.5 `services.json` entry (append to `services`)

```json
{
  "name": "vscode",
  "unit": "vscode.service",
  "container": "systemd-vscode",
  "host_port": 3113,
  "container_port": 8000,
  "bind": "127.0.0.1",
  "health": "/",
  "tier": "optional",
  "image": "localhost/vscode:<VSCODE_VERSION>",
  "boot": false,
  "auth": "token",
  "note": "VS Code Server (serve-web) in an Arch dev box; px=1000 keep-id (fish login shell), sudo inside; host podman socket mounted (distrobox-style); ~/workspace at same path; GPU devices visible via AddDevice=all but NO gpu field (deliberate: outside arbiter); loopback publish, tailnet door via tailscale serve https :8443 (real FQDN never committed)"
}
```

## 4. Build & enable sequence

1. `mkdir -p ~/.homes/vscode/px && chmod 700 ~/.homes/vscode/px`
2. Generate `~/.config/containers/config/vscode/service.env` via the existing
   secrets generator flow (repo ships only the `.example`).
3. Put the files above; put the real tag everywhere `<VSCODE_VERSION>` appears;
   add `"vscode"` to `GPU_DEVICE_OK` in `tests/test-quadlet-policy.sh`.
4. `scripts/build-images.sh --rebuild vscode`
5. `systemctl --user daemon-reload && systemctl --user start vscode.service`
6. Wire the tailnet door (one-time, host):
   `tailscale serve --https=8443 http://127.0.0.1:3113` — verify with
   `tailscale serve status`. From any tailnet device: open
   `https://ai.<TAILNET>.ts.net:8443` and enter the connection token.
   (Fallback without tailnet: from the laptop `ssh -L 8000:127.0.0.1:3113 ai`
   → `http://localhost:8000`.)

## 5. Acceptance checks (run each; all must pass)

```bash
systemctl --user status vscode.service                  # active (running)
podman exec systemd-vscode id -u                        # 1000 (keep-id -> host px)
podman exec systemd-vscode getent passwd px             # shell = /usr/bin/fish
podman exec systemd-vscode sudo -n true                 # container-root, passwordless
podman exec systemd-vscode sh -c 'command -v mise nvim fish git'   # all present
podman exec systemd-vscode nvidia-smi -L                # both cards visible (CDI)
podman exec systemd-vscode podman ps -a                 # shows HOST containers
podman exec -it systemd-vscode fish -c 'podman run --rm -v $HOME/.workspaces/vscode:/w busybox ls /w'   # from inside the box: host daemon resolves HOST paths — use ~/.workspaces/vscode, not the container's ~/workspace
podman exec systemd-vscode sh -c 'touch ~/workspace/marker && ls ~/.workspaces 2>/dev/null' # container ~/workspace is the mounted box dir
curl -fsS http://127.0.0.1:3113/ | head -c200           # VS Code Server login page
tailscale serve status                                  # shows https :8443 -> 127.0.0.1:3113 alongside the existing / route (dufs)
# from a tailnet device (laptop): https://ai.<TAILNET>.ts.net:8443 -> login page, token accepted
tests/test-quadlet-policy.sh && tests/test-registry-consistency.sh   # repo gates stay green
```

## 6. Update / maintenance policy

- **Pin bumps are deliberate**: edit `ARG VSCODE_COMMIT` (+base digest if
  wanted), rebuild, flip the tag in `quadlets/vscode.container` +
  `services.json`, restart. Nothing in the box is mutable except the
  persisted home.
- **Pacman inside the container persists where?** NO — `sudo pacman -S`
  changes the *container*, which is recreated from the image on restart.
  Tool packages you want permanent belong in the Containerfile. Anything
  under `/home/px` (mise toolchains under `~/.local/share/mise`, pip/uv/npm
  user installs, AUR helpers' caches) persists. The guest runs **mise
  pacman-managed like the host** but with its own `~/.config/mise/config.toml`
  in the persisted home — copy the host pins (`mise settings`, or just
  `mise use` go/node/python/rust/uv there once) rather than mounting host
  config, so the two boxes evolve independently. This matches your
  dependency-management rule and keeps rebuilds cheap.
- **fish**: login shell of px (verified: the Arch fish package registers
  `/usr/bin/fish` in `/etc/shells`, host `/etc/shells` confirms). VS Code's
  integrated terminal picks up `$SHELL` automatically; `config.fish` and
  fisher plugins live in the persisted `~/.config/fish` — copy, don't mount,
  the host's config (the box should own its dotfiles).
- **Backups**: `~/.homes/vscode/px` is under `~` (not synced by syncthing,
  which covers only `~/Documents` + `~/workspace`). Add an occasional
  `podman`-level or systemd backup for the home if it becomes precious —
  out of scope for v0.1.
- **Git inside**: keys live in the persisted `~/.homes/vscode/px/.ssh`
  (generate inside; do not mount the host's `.ssh` — that leaks host
  identities into a box whose root can also drive the host's Podman).

## 7. Explicitly NOT doing (deferred)

- **Connection-token rotation**: add `vscode` to `scripts/rotate-secrets.sh`
  (`rotate_env_key "$CONF/vscode/service.env" VSCODE_CONNECTION_TOKEN` +
  restart `vscode.service` + re-bootstrap the browser with `?tkn=<new>`).
  Mechanism already exists; only the one line is missing. Noted 2026-11-03.
- **`--connection-token-file` instead of `--connection-token`**: keeps the
  token out of the serve-web argv, where host `ps`/`systemctl status` expose
  it to any local user. One-line entrypoint change; also makes the rotation
  above cheaper (swap the file, restart). Noted 2026-11-03.
- **Login UX note (verified 1.144.1)**: serve-web renders NO HTML login page
  on an unauthenticated navigation — the browser sees plain-text
  "Forbidden." (the token gate working). First visit must be
  `https://ai.<TAILNET>.ts.net:8443/?tkn=<token>`; the `vscode-tkn` cookie
  lasts 7 days, after which the bare URL works again. The §5 curl check
  passes only through this cookie flow.

- caddy TLS front for direct LAN browser use — motivation superseded by
  tailscale serve; revisit only if a non-tailnet LAN client ever matters.
- `code tunnel` for desktop-client sessions (one entrypoint flag away).
- CUDA toolkit inside the image (driver+devices already pass through via
  CDI; install the toolkit with mise/user installs in the persisted home
  when real GPU work starts).
- code-server (OSS) variant — table in §1 documents the tradeoff if the
  MS license ever becomes a problem.
