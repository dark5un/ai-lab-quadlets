# Agentic pipeline plan: Concourse CI + S3 + git forge on the ai-lab quadlet stack

Status: EXECUTED 2026-11-10 (all 7 pipeline units deployed, boot-enabled via
drop-ins, acceptance battery green except: svc: doors pending tailnet console
approval for svc:forge/svc:s3/svc:concourse; reboot drill on request).
Execution errata found against live (all fixed in-repo):
  - quadlet key for CMD override is `Exec=`, not `Command=` (podman 6.1.4
    quadlet rejects Command= — generator error observed live).
  - Forgejo 17: no UserNS=keep-id (its s6 entrypoint needs container-root);
    named volume forge-ssh instead of a host dir bind; volumes pre-chowned
    1000:1000; admin/token/repo via `forgejo admin ... --user git`.
  - Concourse keys: ALL RSA-PEM (`ssh-keygen -t rsa -m pem`) — ed25519 is
    rejected by flag.PrivateKey (asn1 pkcs8 crash on web start).
  - worker baggageclaim driver: btrfs (home storage is btrfs; kernel overlay
    refuses btrfs upperdir) — flag is CONCOURSE_BAGGAGECLAIM_DRIVER.
  - worker needs host kernel modules ip_tables/iptable_nat/br_netfilter
    (added /etc/modules-load.d/ai-lab-pipeline.conf on this node).
  - garage v2.5.0 CLI: no --output-json on key create; status section is
    "HEALTHY NODES"; key create prints "Key ID:"/"Secret key:" labels.
  - s3-resource v2.5.7 (AWS SDK v2): endpoint must carry the http:// scheme;
    put param `file` is the LOCAL path, not the bucket key.
  - registry-image source key is `repository:`, not `uri:`.
  - fly 8.3.3 confirmation TUI: set-pipeline/set-team need --non-interactive.
  - MCP python SDK is 2.x now: MCPServer (not FastMCP); transport security
    allowlist set for the two verified Hosts.
All product claims below were verified live on 2026-11-10 against official
project APIs, vendor docs, the installed podman-systemd.unit(5) man page, and
live probes on this box (see Appendix A). Tailnet FQDNs are placeholder-only
per public-repo hygiene.

## 1. Goal

Three new services on the existing `ai.network` (podman network
`systemd-ai`, 10.89.0.0/24):

- Concourse CI  — the orchestrator of the agentic pipeline
- S3-compatible object storage — artifact/release bucket for Concourse `s3` resources
- GitHub-like forge — git remote for Concourse `git` resources

plus a thin MCP server so Hermes can drive Concourse directly, and full
persistence of every stateful path on the host. All three are exposed on the
tailnet only; nothing new listens beyond loopback except forge SSH.

Topology (in-network addressing, verified live):

    vscode box (systemd-vscode, already on ai.network)
        | git / S3 / fly / MCP
        v
    systemd-forge:3000    systemd-s3:3900    systemd-concourse-web:8080
    (Forgejo)             (Garage)           (Concourse web+TSA)
                                                ^ systemd-concourse-worker:2222 (TSA)
    systemd-forge-pg:5432 | systemd-concourse-pg:5432  (private DBs, no host port)

    Concourse worker's inner containers resolve siblings via
    CONCOURSE_CONTAINERD_DNS_SERVER=10.89.0.1 (aardvark-dns on the
    systemd-ai gateway — probe showed every container on the net gets
    `nameserver 10.89.0.1` + `search dns.podman`).

## 2. Research verdicts

### 2.1 S3-compatible object storage -> Garage (dxflrs/garage v2.5.0)

Verified state of the candidates (2026-11-10):

| candidate | version / status (verified) | verdict |
|---|---|---|
| MinIO | github.com/minio/minio `archived: true` (2026-04-25), last push 2026-04-24; no community binaries/images since Oct 2025 (source-only) | REJECT — dead as a self-hostable product; you would own CVE response forever |
| S3Proxy | gaul/s3proxy, active (pushed 2026-11-09) | REJECT — it is a Java translation gateway (S3 -> GCS/Azure/fs) and a test double, not a storage service |
| RustFS | 1.0.4 (GA 1.0.0 2026-09-16); issue tracker shows active correctness bugs (quorum recovery, multipart 503s, scanner OOM) | REJECT for now — closest MinIO clone if we ever migrate a MinIO estate, but <3 months GA |
| SeaweedFS | 4.53 (2026-11-08), Apache-2.0, mature since 2012 | RUNNER-UP — best if we ever need a POSIX/HDFS filer; more moving parts (master+volume+filer) for a pure S3 need |
| Ceph RGW | mature | REJECT — 16GB+ RAM class; massive overkill for one bucket |
| Garage | v2.5.0 (2026-10-24), AGPLv3, in production at Deuxfleurs since 2020; official image dxflrs/garage (26MB); single-node mode is first-class | PICK |

Why Garage for this job: one binary, one config file, S3 API that the
Concourse s3-resource's documented compatibility knobs target (path-style,
plain-HTTP endpoint, region — all verified in the s3-resource README, sec.
2.4), admin via `podman exec systemd-s3 /garage ...`, and an upgrade path to
3-node geo-replication across the tailnet later without changing clients.
AGPL is fine: internal deployment, no redistribution. The stack's
`ragflow-minio` stays put; RAGFlow pins MinIO itself — replacing that one is
a separate decision.

Compatibility check that mattered: the Concourse s3-resource supports
`endpoint`, `disable_ssl`, `use_path_style`, `skip_s3_checksums`,
`disable_multipart` (verified in README parameter list) — exactly the set
needed to talk to Garage over the container network with no TLS.

### 2.2 Git forge -> Forgejo (codeberg.org/forgejo/forgejo, 17.0.1)

Verified feature comparison (both docs pages fetched 2026-11-10):

| | Gitea | Forgejo | Gogs |
|---|---|---|---|
| latest release | v28.3.0 (2026-11-01) | v17.0.1 (2026-10-26) | (not current-relevant) |
| Actions CI | yes | yes | NO |
| package registries | 23 (Terraform yes, ALT no) | 23 (ALT yes, Terraform not in docs index) | NO |
| issues/PR/reviews/wiki/orgs | yes | yes | basic only |
| federation (ActivityPub) | no | yes (opt-in) | no |
| extra admin: soft-quota, incoming-email-to-comment, commit-signing, moderation | partial | yes (docs TOC) | no |
| governance | CommitGo Inc. (commercial), MIT | Codeberg e.V. non-profit, GPL-3.0; tested-before-merge policy; LTS line | — |

"Gitea-like" is not a feature race anymore: Gitea and Forgejo share the
lineage and the day-to-day feature delta is ~one registry format (Terraform
vs ALT) plus Forgejo's federation/admin extras. The decisive factor is the
lesson we just learned from MinIO twice this year: pick the project whose
code cannot be rug-pulled by a company pivot. Forgejo is community-governed
(non-profit), publishes an LTS policy, has a hard-fork-tested upgrade path
from Gitea, and the Forgejo docs ship an official Podman quadlet install
section. Concourse is agnostic — its `git` resource clones any HTTP(S) or
SSH git remote.

Note: Gitea would be picked instead only if the Terraform registry is a
requirement (not currently on the stack roadmap).

### 2.3 CI -> Concourse v8.3.3 (unchanged, requested)

Verified: repo active (not archived), v8.3.3 released 2026-11-03 with CVE
patches; bundled resource types in 8.3.3 include `git: v1.24.1` and
`s3: v2.5.7` (plus time, registry-image, docker-image) — so BOTH pipeline
edges we need (forge->git, s3 artifacts) are built into the image; no
resource images to pin separately. Concourse requires PostgreSQL >= 11
(official docs), needs web+worker split with 3 SSH/RSA key pairs
(generating-keys doc), and the official worker guidance for container DNS
is `CONCOURSE_CONTAINERD_DNS_SERVER` + `CONCOURSE_CONTAINERD_ALLOW_HOST_ACCESS=true`
(verified flag names on the running-worker doc page).

The official quickstart `command: quickstart` single-container mode exists
(verified in concourse-ci.org/docker-compose.yml) but regenerates state
per boot; we deploy the production-shape web+worker pair instead.

### 2.4 MCP for Concourse -> build a thin one (no usable existing server)

Verified: the only Concourse MCP project found is
centralci/cci-visual-mcp-server — an Electron desktop app, v0.0.1, 11
commits, not a headless server. Nothing else is registered. So the plan
builds a small HTTP MCP server wrapping the ATC REST API. The API surface
was verified against the real router table (atc/routes.go @ master):
pipelines (SaveConfig/unpause/expose), jobs (CreateJobBuild, pause/unpause,
schedule), builds (List/Create/Abort/events/WebSocket BuildEvents),
resources (CheckResource, PinResourceVersion, UnpinResource,
ListResourceVersions, enable/disable version), workers, plus
`/api/v1/hooks/repo/...` (CheckResourceWebHook) — which also allows a
Forgejo webhook to trigger instant resource checks.

Tools exposed initially (MCP, streamable HTTP):
`list_pipelines, get_pipeline_config, set_pipeline, trigger_job, build_status,
tail_build_events, abort_build, list_resources, pin_resource, unpin_resource,
pause_unpause_job, list_workers`.

Auth detail left explicitly open for build-time (one thing not re-verified
from primary source in this session): the exact skymarshal token endpoint
for a machine user (fly does an OAuth2 dance; a long-lived API token via
`fly login --token` or a client-credentials grant needs pinning against
skymarshal code/docs when we write the image). Flagged in Appendix B.

## 3. Persistence policy (host-side, per user requirement)

Every stateful path lives on the host. Following the standing convention
(heavy per-service state = named podman volumes, which physically live in
~/.local/share/containers/storage/volumes/ on this machine, not in home
dirs), plus host config dirs for secrets/config files:

| state | where | quadlet |
|---|---|---|
| Forgejo git repos + LFS + avatars + attachments + app.ini | named volume `forge-data` -> /data | `Volume=forge-data:/data` |
| Forgejo DB (Postgres 18) | named volume `forge-db-data` | `Volume=forge-db-data:/var/lib/postgresql` |
| Garage object data | named volume `garage-data` -> /var/lib/garage/data | `data_dir` in garage.toml points there |
| Garage metadata (LMDB/SQLite) | named volume `garage-meta` -> /var/lib/garage/meta | `metadata_dir` in garage.toml |
| Concourse ATC DB (Postgres 18) | named volume `concourse-db-data` | per-app split (kb-postgres precedent: blast-radius isolation) |
| Concourse worker volume graph (`CONCOURSE_WORK_DIR=/worker-state`, verified from image config) | named volume `concourse-worker-state` | `Volume=concourse-worker-state:/worker-state` |
| Concourse keys (tsa_host_key, worker_key, session_signing_key) | `config/concourse/keys/` in the repo's config tree (0600, generated on-target, ro bind) | NOT in volumes — re-deployable without worker re-registration churn |
| garage.toml, service.env secrets | `config/{s3,forge,concourse}/` (600, generated on-target; `.example` only in git) | ro bind / EnvironmentFile |

Databases: YES, persist both. They hold pipeline runs/jobs (Concourse) and
users/repos/issues (Forgejo) — losing them on container recreation would be
losing the product. The Postgres images declare no fixed data subdir for PG18
at `.../data`: the pg18 official layout is `/var/lib/postgresql` parent mount
(kb-postgres comment: docker-library/postgres#1259).

Backup: `podman volume export forge-data -o ...` (+ the others), config dirs
are files; all under the existing syncthing-free heavy-state rule.

## 4. Ports and tailnet doors (verified against registry + live listeners)

services.json + PublishPort grep + `ss -ltn` all checked 2026-11-10:
3100-3119 taken, 2222/2223 free, 100.x tailscale-serve https ports used:
443(root->3112), 8443, 8444, 8446, 8447, 8448. svc: precedent exists on this
node (svc:notebook, svc:sketchlab, svc:windmill all live in
`tailscale serve status`).

| service | host port (loopback unless noted) | container port | door |
|---|---|---|---|
| forge web | 3120 | 3000 | svc:forge -> https://forge.<tailnet>.ts.net |
| forge git SSH | 2223 | 22 | direct: `ssh://git@<node-tailnet-ip>:2223/...` (TCP, not serve-able; LAN exposure — see note) |
| garage S3 | 3121 | 3900 | svc:s3 -> https://s3.<tailnet>.ts.net (optional; host CLIs can use 127.0.0.1:3121) |
| concourse web | 3122 | 8080 | svc:concourse -> https://concourse.<tailnet>.ts.net |
| concourse TSA | none | 2222 | in-network only (worker -> systemd-concourse-web:2222) |
| concourse-postgres | none | 5432 | in-network only (kb-postgres precedent) |
| forge-postgres | none | 5432 | in-network only |
| concourse-mcp | 3123 | 8080 | host-only (Hermes on this box) |

Notes:
- svc doors are the subdomain shape; their procedure/prereqs are verified in
  references/tailscale-services-doors.md (node is already tagged +
  autoApprovers exist — three svc: doors already live).
- The 0.0.0.0:2223 SSH publish also opens on LAN; acceptable on the home net,
  but flag at enable time. If the host firewall is default-deny, verify with
  `nft list ruleset` (not yet probed — Appendix B).
- Tailscale Services certs chain to the tailnet CA, which is NOT in this
  box's system trust (probed: no tailscale CA under /etc/ssl/certs). Browsers
  on tailnet clients trust it automatically; CLI clients off-box need the
  tailnet root CA or loopback.
- Concourse `CONCOURSE_EXTERNAL_URL=https://concourse.<tailnet>.ts.net` keeps
  the app at URL root (websocket-heavy) per the serve precedent.

## 5. The quadlet configurations

House conventions applied (verified against live files + man page):
`Network=ai.network` (materializes systemd-ai, auto Wants/After ai-network
not relied on — explicit Wants=/After= one-per-line as policy tests grep),
loopback PublishPort, EnvironmentFile=%h/.config/containers/config/<svc>/,
SuccessExitStatus=143, Restart=on-failure, NO `[Install]` in shipped
repo templates (dormant by default; activate via drop-in per stack rule).
podman 6.1.4 man page has NO native `Privileged=` key -> PodmanArgs.

### 5.1 forge.container (Forgejo)

```ini
# forge.container — Forgejo git forge (Codeberg e.V., GPL-3.0, v17.0.1).
# Repos/LFS/attachments persist in named volume forge-data (host container
# storage). DB = forge-postgres sidecar (no host port). Digest pin: tag
# 17.0.1 == 17 (index digest verified 2026-11-10).
[Unit]
Description=Forgejo git forge
Wants=ai-network.service
Wants=forge-postgres.service
After=ai-network.service
After=forge-postgres.service

[Container]
ContainerName=systemd-forge
Image=codeberg.org/forgejo/forgejo@sha256:fcd19ff4ebc85fb098a67e8e1d0d5a84d07dd6e8a23edcfdfd5b71a6178953be
Network=ai.network
UserNS=keep-id
# forgejo's stock entrypoint creates/chowns /data as USER_UID/USER_GID
Environment=USER_UID=1000
Environment=USER_GID=1000
# FORGEJO__<section>__<KEY> maps to app.ini (verified, admin docker docs)
Environment=FORGEJO__server__ROOT_URL=https://forge.<tailnet>.ts.net
Environment=FORGEJO__server__DOMAIN=forge.<tailnet>.ts.net
Environment=FORGEJO__server__SSH_DOMAIN=<node-tailnet-hostname>
Environment=FORGEJO__server__SSH_PORT=2223
Environment=FORGEJO__server__SSH_LISTEN_PORT=22
Environment=FORGEJO__service__DISABLE_REGISTRATION=true
Environment=FORGEJO__database__DB_TYPE=postgres
Environment=FORGEJO__database__HOST=systemd-forge-pg:5432
EnvironmentFile=%h/.config/containers/config/forge/service.env
# DB name/user/passwd + admin bootstrap in service.env (FORGEJO__database__NAME/USER/PASSWD)
Volume=forge-data:/data
Volume=forge-ssh:/data/ssh   # (execution fix 2026-11-10: host dir bind +
# UserNS=keep-id both break Forgejo 17's s6 entrypoint; run ns-root + named volume)
# web loopback; git SSH host port 2223 (also LAN-reachable; see plan sec.4)
PublishPort=127.0.0.1:3120:3000/tcp
PublishPort=0.0.0.0:2223:22/tcp

[Service]
SuccessExitStatus=143
Restart=on-failure
RestartSec=10
TimeoutStartSec=300
TimeoutStopSec=120
```

Plus the sidecar (modelled 1:1 on kb-postgres):

```ini
# forge-postgres.container — private Postgres 18 for Forgejo (no host port).
[Unit]
Description=Forgejo PostgreSQL
Wants=ai-network.service
After=ai-network.service

[Container]
ContainerName=systemd-forge-pg
Image=docker.io/library/postgres@sha256:e3d24f6906d0760bf4da0dae872415391ededefad23fd471c47dc53b0ddf3c42
Network=ai.network
UserNS=keep-id
EnvironmentFile=%h/.config/containers/config/forge/postgres.env
Volume=forge-db-data:/var/lib/postgresql

[Service]
SuccessExitStatus=143
Restart=on-failure
RestartSec=10
TimeoutStartSec=300
```

Volumes are created at install (`podman volume create forge-data
forge-db-data ...`) and owned via keep-id + USER_UID/GID matching px (1000).

### 5.2 s3.container (Garage)

```ini
# s3.container — Garage S3 (Deuxfleurs, AGPLv3, v2.5.0, single node).
# Buckets/objects persist in named volumes garage-data/garage-meta (host
# container storage). Config + secrets live in config/s3/garage.toml
# (0600, generated on-target). Admin CLI: podman exec systemd-s3 /garage ...
[Unit]
Description=Garage S3 object storage (single node)
Wants=ai-network.service
After=ai-network.service

[Container]
ContainerName=systemd-s3
Image=docker.io/dxflrs/garage@sha256:677e5b758e4425a325b811c425c026bf35a4bf42f7ddbaa773de3f4fd779a5a5
Network=ai.network
# image Cmd=["/garage","server"] (verified via registry config blob);
# podman 6.1.4 quadlet key overriding CMD is Exec= (Command= is NOT
# supported by this version - live-verified via quadlet-generator error):
Exec=/garage server --single-node
Volume=%h/.config/containers/config/s3/garage.toml:/etc/garage.toml:ro
Volume=garage-meta:/var/lib/garage/meta
Volume=garage-data:/var/lib/garage/data
# S3 API loopback (3121). 3902/3903 (web hosting/admin) intentionally not
# published; admin is the exec CLI.
PublishPort=127.0.0.1:3121:3900/tcp

[Service]
SuccessExitStatus=143
Restart=on-failure
RestartSec=10
TimeoutStartSec=300
```

`config/s3/garage.toml` (generated on-target; keys per verified quick-start
reference):

```toml
metadata_dir = "/var/lib/garage/meta"
data_dir = "/var/lib/garage/data"
db_engine = "sqlite"
replication_factor = 1
rpc_bind_addr = "[::]:3901"
rpc_public_addr = "127.0.0.1:3901"   # single node; loopback RPC
rpc_secret = "<openssl rand -hex 32>"
[s3_api]
s3_region = "garage"
api_bind_addr = "[::]:3900"
root_domain = ".s3.ai-lab.localhost"
[s3_web]
bind_addr = "[::]:3902"
root_domain = ".web.ai-lab.localhost"
index = "index.html"
[admin]
api_bind_addr = "[::]:3903"
admin_token = "<openssl rand -base64 32>"
metrics_token = "<openssl rand -base64 32>"
```

Bootstrap (one-time, after start):

```
podman exec systemd-s3 /garage status
podman exec systemd-s3 /garage layout apply --version 1
podman exec systemd-s3 /garage bucket create ci-artifacts
podman exec systemd-s3 /garage key create hermes
podman exec systemd-s3 /garage bucket allow --read --write ci-artifacts --key hermes
```

(s3 key/secret printed once, stored in config/s3/service.env next to the
toml; never in git/argv.)

### 5.3 concourse-web.container + concourse-worker.container

```ini
# concourse-web.container — Concourse v8.3.3 web (ATC+TSA+UI).
# Pipeline state persists in concourse-postgres (private). Keys live in
# config/concourse/keys/ on the host (ro bind). external URL = svc door.
[Unit]
Description=Concourse web (ATC + TSA + UI)
Wants=ai-network.service
Wants=concourse-postgres.service
After=ai-network.service
After=concourse-postgres.service

[Container]
ContainerName=systemd-concourse-web
Image=docker.io/concourse/concourse@sha256:5d3a30f336b063b9ed0bb2b963044b5782dc06d8efd1161e85202d60de26e923
Network=ai.network
Exec=web
Volume=%h/.config/containers/config/concourse/keys:/concourse-keys:ro
EnvironmentFile=%h/.config/containers/config/concourse/web.env
# web.env (0600, generated): CONCOURSE_EXTERNAL_URL=https://concourse.<tailnet>.ts.net
#   CONCOURSE_SESSION_SIGNING_KEY=/concourse-keys/session_signing_key
#   CONCOURSE_TSA_HOST_KEY=/concourse-keys/tsa_host_key
#   CONCOURSE_TSA_AUTHORIZED_KEYS=/concourse-keys/worker_key.pub
#   CONCOURSE_POSTGRES_HOST=systemd-concourse-pg  (+ user/pass/database)
#   CONCOURSE_ADD_LOCAL_USER=pipeline:<generated>
#   CONCOURSE_MAIN_TEAM_LOCAL_USER=pipeline
#   CONCOURSE_CLUSTER_NAME=agentic-pipeline
PublishPort=127.0.0.1:3122:8080/tcp
# TSA :2222 stays unpublished: the worker reaches systemd-concourse-web:2222

[Service]
SuccessExitStatus=143
Restart=on-failure
RestartSec=10
TimeoutStartSec=300
```

```ini
# concourse-worker.container — Concourse v8.3.3 worker (privileged:
# runs containerd+overlay for builds; no native quadlet Privileged= key in
# podman 6.1.4 man page -> PodmanArgs, plus --cgroupns=host per official
# compose guide).
[Unit]
Description=Concourse worker (containerd/overlay)
Wants=ai-network.service
Wants=concourse-web.service
After=ai-network.service
After=concourse-web.service

[Container]
ContainerName=systemd-concourse-worker
Image=docker.io/concourse/concourse@sha256:5d3a30f336b063b9ed0bb2b963044b5782dc06d8efd1161e85202d60de26e923
Network=ai.network
Exec=worker
PodmanArgs=--privileged --cgroupns=host
StopSignal=SIGUSR2
Volume=%h/.config/containers/config/concourse/keys:/concourse-keys:ro
# build volume graph + overlay store persist on the host:
Volume=concourse-worker-state:/worker-state
EnvironmentFile=%h/.config/containers/config/concourse/worker.env
# worker.env (0600):
#   CONCOURSE_TSA_HOST=systemd-concourse-web:2222
#   CONCOURSE_TSA_PUBLIC_KEY=/concourse-keys/tsa_host_key.pub
#   CONCOURSE_TSA_WORKER_PRIVATE_KEY=/concourse-keys/worker_key
#   CONCOURSE_WORKER_BAGGAGECLAIM_DRIVER=overlay
#   CONCOURSE_CONTAINERD_DNS_SERVER=10.89.0.1     (aardvark on the net gateway; live-verified)
#   CONCOURSE_CONTAINERD_ALLOW_HOST_ACCESS=true   (pair per running-worker doc "local DNS server")
#   CONCOURSE_NAME=worker-01

[Service]
SuccessExitStatus=143
Restart=on-failure
RestartSec=10
TimeoutStartSec=600
TimeoutStopSec=180
```

`concourse-postgres.container` is the same sidecar shape as
forge-postgres (distinct volume `concourse-db-data`, distinct env file; DB
named/user `atc` is Concourse's default per running-postgres doc).

Key generation (once, into config/concourse/keys/, chmod 600):

```
ssh-keygen -t rsa -m pem -f tsa_host_key -N ''
ssh-keygen -t rsa -m pem -f session_signing_key -N ''
ssh-keygen -t rsa -m pem -f worker_key -N ''
cp worker_key.pub authorized_worker_keys
# (execution erratum 2026-11-10: ALL keys RSA-PEM per docs/install/generating-keys
# + flag/private_key.go; the ed25519 forms this plan first carried are rejected:
# web dies parsing --tsa-worker-private-key with an asn1 pkcs8 error)
```
(matches the three key roles in the official generating-keys page; fly logs
in over the svc:concourse door or 127.0.0.1:3122).

### 5.4 Pipeline wiring (Concourse -> forge + S3), verified parameters

```yaml
resources:
- name: repo
  type: git                      # bundled v1.24.1
  source:
    uri: http://systemd-forge:3000/pipeline/<repo>.git
    branch: main
    username: ((forge-user))     # git-resource HTTPS basic auth (verified)
    password: ((forge-token))
- name: artifacts
  type: s3                       # bundled v2.5.7
  source:
    bucket: ci-artifacts
    endpoint: systemd-s3:3900    # README: "Can be just a hostname" (verified)
    disable_ssl: true            # README param (verified)
    region_name: garage          # Garage s3_region (verified garage.toml)
    access_key_id: ((s3-ak))
    secret_access_key: ((sk))
    versioned_file: build/latest.tar.gz
```

Creds via Concourse vars / credhub-less static team vars. Optional later:
Forgejo webhook -> `http://systemd-concourse-web:8080/api/v1/hooks/repo/git/<resource-name>`
(CheckResourceWebHook route verified in routes.go) for instant triggers.

## 6. vscode box integration

`systemd-vscode` is already on ai.network, and the in-network name resolution
is live-verified (a container resolved systemd-windmill-server -> .dns.podman
via 10.89.0.1). The box reaches all four services by container DNS — no
quadlet change needed for connectivity. To make the box useful for the
pipeline (bake into the vscode image per the "install in container = bake in
Containerfile" rule):

- `fly` client (fetch from the running web node: GET /api/v1/cli?arch=amd64&platform=linux — shape verified on quickstart page), plus
- Arch extra `aws-cli-v2` (S3), `git`, `openssh`
- persistent `~/.fly` + git credential store inside the home volume
  (`/home/px` = ~/.homes/vscode/px — survives recreates)
- endpoints documented in the box's dotfiles:
  git: http://systemd-forge:3000 (token auth) / ssh://git@<tailnet>:2223
  S3:  http://systemd-s3:3900 (region garage, path-style)
  fly: -t http://systemd-concourse-web:8080 (in-net) or the svc door

## 7. Hermes + in-pipeline MCP (concourse-mcp)

New built image `localhost/concourse-mcp` (uv-managed Python MCP server,
streamable HTTP on :8080) + a standard quadlet `concourse-mcp.container`
(Network=ai.network, EnvironmentFile config/concourse/mcp.env). One
endpoint serves BOTH consumers because it lives on ai.network:

- **Hermes on the host**: PublishPort=127.0.0.1:3123:8080, config
  (~/.hermes/config.yaml, shape verified from docs mcp-config-reference):

```yaml
mcp_servers:
  concourse:
    url: "http://127.0.0.1:3123/mcp"
    headers:
      Authorization: "Bearer <mcp-static-token>"
    tools:
      exclude: [abort_build]   # start conservative; allow after trust is earned
```

- **From inside Concourse pipelines**: task/resource containers reach it
  in-network at http://systemd-concourse-mcp:8080/mcp — the same
  worker-inner DNS path used for forge/S3 (aardvark 10.89.0.1 +
  ALLOW_HOST_ACCESS=true already set in 5.3), so no extra wiring.
  This lets an agent step inside a build inspect/pin/trigger other
  pipelines (e.g. triage job -> pin the failing dep, rerun a job).
  Security: pipeline-origin calls MUST use a SEPARATE low-privilege MCP
  token bound to a restricted Concourse team (the MCP server maps
  bearer token -> team creds); never hand tasks the Hermes-grade token.

Server auth to ATC (machine user, dedicated `agent` team via fly
set-team) and MCP->REST translation for the routes in sec. 2.4.

## 7.1 Running prompts from inside Concourse (agentic tasks)

Verified live on this box: the stack's model servers speak
OpenAI-compatible HTTP and are on ai.network
(`curl /health` -> `{"model":"qwen3.8-flash-next-iq3_s","max_context":1048576,"api_key":true}`
on systemd-strata:8080; same auth-gated /v1/chat/completions shape on
llama-cpp-4070ti; both return 401 without a key). So a pipeline task runs
prompts with no new service:

```yaml
- task:
    file: agent-task.yml          # image: python:3.14-slim (or an agent-cli image)
    config:
      env:
        OPENAI_BASE_URL: http://systemd-strata:8080/v1
        OPENAI_API_KEY: ((strata-key))     # Concourse team var
```

Patterns the pipeline can then express:

1. **Task calls a model** directly (review/summarize/classify build output)
   via the OpenAI endpoint above.
2. **Task runs a tool-using agent** (small loop: model + MCP tool calls)
   against systemd-concourse-mcp:8080/mcp — the agentic pipeline itself.
3. **webhook-driven wakeups** later: a separate `ci-listener` container on
   ai.network receives Forgejo webhooks and calls
   `POST /api/v1/.../builds` on systemd-concourse-web. Not in this phase —
   the pipeline is poll-based (`check_every`), which works immediately
   because Forgejo+Concourse already share the network.

Ops notes (flagged in the pipeline README at build time):
- Task concurrency must respect GPU arbiter policy: llama-cpp-4070ti is
  `boot=false` (started on demand); a task expecting it must fail loudly,
  not silently queue. Strata holds a card while running — pipeline prompts
  share it with interactive use; cap `max_containers` on the worker if
  agent storms are a concern (`CONCOURSE_CONTAINERD_MAX_CONTAINERS`
  verified in the worker flag dump).
- The worker's inner network pool is 10.80.0.0/16 by default (verified) —
  it NATs out through the worker into systemd-ai, so all container-DNS
  targets are reachable but return traffic is stateful-NAT only.

## 8. Enablement & stack integration (implementation steps)

1. `podman volume create forge-data forge-db-data garage-meta garage-data concourse-db-data concourse-worker-state`
2. Generate `config/{forge,s3,concourse}/*.env`, keys, garage.toml per the
   secrets convention (generator = scripts/generate-secrets.sh block; add
   forge/s3/concourse there). Never commit values.
3. Add repo `quadlets/*.container` files WITHOUT [Install] (dormant).
4. services.json: add slots forge=3120, forge-pg (no host port), s3=3121,
   concourse-web=3122, concourse-mcp=3123 (+2223 SSH note, concourse-worker
   no host port, concourse-pg no host port); append port-plan.md rows.
5. install.sh: UNITS array + copy_examples entries; policy tests: allowlist +
   the worker's `GPU_DEVICE_OK`-style exception for `--privileged` if the
   test greps PodmanArgs shape; re-run tests/.
6. Enable: drop-in [Install] WantedBy=default.target for the four boot-tier
   units (forge, forge-pg, s3, concourse trio), daemon-reload, start web
   before worker; `loginctl show-user px -p Linger` = yes (verified).
7. Doors: create svc:forge / svc:s3 / svc:concourse in the console,
   `tailscale serve --service=svc:<name> --https=443 http://127.0.0.1:<port>`
   (auto-backgrounds with --service; flow verified in
   references/tailscale-services-doors.md; watch the #18821 stuck-approval
   pitfall: clear + re-advertise).
8. Acceptance tests (must all pass before "done"):
   - `podman exec systemd-s3 /garage status` -> 1 node, ready
   - `curl -s http://127.0.0.1:3120/api/v1/version` -> Forgejo version
   - `fly -t local login -c http://127.0.0.1:3122` + `fly workers` -> worker-01 landing
   - set the sec-5.4 pipeline; `fly check-resource` on git -> commit SHA found
   - `fly trigger build`; s3 out step; then
     `aws s3 ls s3://ci-artifacts/build/ --endpoint-url http://127.0.0.1:3121`
   - from a throwaway container on ai.network and from inside a Concourse
     task (`fly execute`): `nslookup systemd-forge systemd-s3 systemd-concourse-web`
     + `curl http://systemd-s3:3900` -> proves the worker-inner-DNS path
   - from vscode box: git clone http://systemd-forge:3000/..., fly targets
   - inside a task (`fly execute` with an image carrying curl/python):
     `curl http://systemd-concourse-mcp:8080/mcp` (MCP handshake) and
     `POST http://systemd-strata:8080/v1/chat/completions` with a team-var
     key -> model reply JSON — proves in-pipeline prompts end-to-end
   - MCP call from a task with the LOW-PRIVILEGE token: trigger a job,
     confirm the main-team token is rejected for the same call
   - Hermes: /reload-mcp, call list_pipelines, trigger_job
   - reboot drill: every unit comes back, `fly workers` green, buckets intact

## Appendix A — what was verified and how (2026-11-10)

- MinIO archived: api.github.com/repos/minio/minio -> archived:true, pushed 2026-04-24.
- Releases via each project's official API: concourse/concourse releases/latest -> v8.3.3 (2026-11-03); gitea -> v28.3.0; RustFS -> 1.0.4; seaweedfs -> 4.53; garage (git.deuxfleurs.fr Gitea API) -> v2.5.0; forgejo (codeberg.org API) -> v17.0.1; s3proxy -> gaul/s3proxy active.
- Concourse bundled resources incl. git v1.24.1 + s3 v2.5.7: v8.3.3 release notes (GitHub API).
- Concourse ATC API routes: atc/routes.go @ master (raw).
- Concourse image layout: registry config blob -> ENV CONCOURSE_WORK_DIR=/worker-state, VOLUME /worker-state; index sha256:5d3a30f3...; amd64 child sha256:9020c16d....
- Garage image layout: registry config blob -> Cmd ["/garage","server"], no declared volumes (paths come from garage.toml).
- Garage single-node config + docker flow + env vars: garagehq.deuxfleurs.fr quick-start.
- Forgejo env format FORGEJO__section__KEY, image codeberg.org/forgejo/forgejo:17, official Podman quadlet example, SSH port mapping '222:22': forgejo.org admin/installation/docker.
- Forgejo tags: codeberg registry probe -> 17, 17.0, 17.0.1 resolve (v17/latest 404); 17 == 17.0.1 digest sha256:fcd19ff4....
- Gitea vs Forgejo registries/docs feature surfaces: docs.gitea.com packages/overview + forgejo.org docs index.
- s3-resource params (endpoint, disable_ssl, use_path_style, region_name...): raw README grep.
- git-resource basic-auth over HTTPS (username/password, private_key for ssh@): raw README grep.
- Worker containerd flags (DNS_SERVER, ALLOW_HOST_ACCESS, CNI pool 10.80.0.0/16): running-worker doc page.
- quadlet keys: man podman-systemd.unit on installed 6.1.4 — Network= accepts --network colon options; StopSignal=, AddHost=, HealthCmd=, Secret= exist; NO Privileged= key.
- podman run supports --cgroupns (installed --help).
- Host facts live: systemd-ai subnet 10.89.0.0/24 gw .1; aardvark-dns on :53; probe container resolv.conf = nameserver 10.89.0.1 + search dns.podman; sibling name resolution + alias verified by live nslookup; ports 3120-3123/2222/2223 free (services.json + PublishPort grep + ss -ltn); tailscale 1.104.4 with live svc: doors (notebook, sketchlab, windmill); Linger=yes; postgres:18 digest pinned from registry.
- Hermes MCP config shape (mcp_servers.<name>.url/headers/tools.exclude, /reload-mcp): hermes docs mcp-config-reference.
- In-stack model endpoints live-probed 2026-11-10: systemd-strata (host 11434) /health -> qwen3.8-flash-next-iq3_s, max_context 1048576, api_key:true; /v1/models and /v1/chat/completions return 401 without key; llama-cpp-4070ti (host 11436) same OpenAI shape (/health 200 {"status":"ok"}). Keys: config/llama-cpp/keys.txt per services.json note; exact strata key file/format to be pinned at build time (my keys.txt line-shape guess returned 401).

## Appendix B — open items for build time

1. skymarshal token grant for a headless MCP user (verify against
   skymarshal docs/code; fallback = fly CLI wrapped by the MCP server).
2. `nft list ruleset` / host firewall posture before opening 0.0.0.0:2223.
3. Whether to run Concourse inside the worker with `fuse-only` privileged
   mode (`CONCOURSE_CONTAINERD_PRIVILEGED_MODE`, flag verified in man dump)
   to soften worker blast radius — default `full` = root-on-host-equivalent.
4. ragflow-minio stays MinIO (RAGFlow pins it); revisit when Garage proves out.
5. Postgres majors: pinned pg18 digests must be re-resolved the session of
   enablement (digest-pinning rule), offline bake via skopeo --preserve-digests.
6. Forgejo SSH_HOST/KEY setup + first admin bootstrap via
   `forgejo admin user create` CLI (docs command-line page), not web UI.
