# Port & orchestration plan

Goal: one coherent port scheme, one source of truth for service metadata,
a CLI control plane, and a Ryoku bar plugin to toggle services.
Strata was frozen at 11437 by this plan; that freeze was later lifted —
strata has since moved to 11434 (model-API family alignment, 2026-10-05).

## Research findings (Phase 0)

- Host ports are all freely rebinding; container-internal ports are fixed
  (llama.cpp/open-webui/sketchlab/hyperframes: 8080, comfyui: 8188,
  hermes: 9119, deepseek-harness: DSH_PORT env, default 3080).
- Host listeners in use: quadlet ports only + ryoku-rashin 127.0.0.1:3600.
  The 31xx range is free.
- The extra-GPU template formula `1{INDEX}43{INDEX}` is broken
  (yields 11431, 12432, 13433).
- Ports are duplicated across quadlets, templates, detect-gpus.sh,
  install.sh, README, docs, and open-webui's service.env (WEBUI_URL/CORS).

## Port scheme (Phase 1)

Model APIs (1143x family, Ollama-adjacent). CURRENT (2026-10-08; services.json
is authoritative, the per-role names and the extra-N formula are gone):

| service                          | port  | binding |
|----------------------------------|-------|---------|
| strata-5090 / -4070ti / -both    | 11434 | LAN, API key |
| llama-cpp-5090                   | 11435 | LAN, API key |
| llama-cpp-4070ti                 | 11436 | LAN, API key |
| rizzo                            | 11437 | LAN     |
| llama-cpp-both                   | 11438 | LAN, API key |

Web apps (31xx family, sequential):

| service            | old  | new  | binding  |
|--------------------|------|------|----------|
| open-webui         | 3000 | 3100 | LAN      |
| comfyui            | 8188 | 3101 | LAN      |
| sketchlab          | 3004 | 3102 | LAN (tailnet: Tailscale Service svc:sketchlab -> https://sketchlab.<tailnet>.ts.net; boot tier per owner directive 2026-11-05) |
| hyperframes        | 3006 | 3103 | LAN      |
| hermes (opt-in)    | 3003 | 3104 | LAN      |
| deepseek-harness   | 3080 | 3105 | loopback (Network=host, dsh binds 127.0.0.1 itself) |
| docling-serve      | 5001 | 3108 | loopback (the docling MCP's remote backend) |
| vscode             | -    | 3113 | loopback (tailnet door: tailscale serve https :8443; fallback ssh -L) |
| s3-webdav          | 8080 | 3124 | loopback (tailnet door: tailscale serve https :8449; rclone serve webdav over Garage buckets — added 2026-11-10) |
| vscode-pr box pool | 8080 | 3130-3135 | loopback; transient per-PR code-server containers (docs/vscode-pr-review-plan.md); fixed tailnet doors https :8450-8455 via scripts/vscode-pr-doors.sh; pool allocations = marker files ~/.workspaces/vscode-pr/port-<p> |

Knowledge base (KB group, plan ~/tmp/knowledge_base_plan1.md, added 2026-11-04):

| service            | port  | binding  |
|--------------------|-------|----------|
| ragflow (UI)       | 3114  | loopback (API 9380 in-network only: systemd-ragflow:9380) |
| lightrag (UI+API)  | 3116  | loopback |
| ragflow-elasticsearch | -  | none (systemd-ragflow-elasticsearch:9200) |
| ragflow-mysql      | -     | none (systemd-ragflow-mysql:3306) |
| ragflow-minio (silo) | -   | none (systemd-ragflow-minio:9000) |
| ragflow-kvrocks    | -     | none (systemd-ragflow-kvrocks:6379) |
| ragflow-nats       | -     | none (systemd-ragflow-nats:4222; distinct from host nats 4222/8222) |
| kb-postgres        | -     | none (systemd-kb-postgres:5432) |

Automation (automation group, plan ~/tmp/windmill-jupyter-plan1.md, added 2026-11-05;
Windmill replaced n8n for KB W1-W4 - n8n 3115 deleted 2026-11-05, port free):

| service            | port  | binding  |
|--------------------|-------|----------|
| windmill-server (UI+API) | 3117 | loopback (tailnet door LIVE: svc:windmill -> https://windmill.<tailnet>.ts.net) |
| windmill-worker    | -     | none (no published port) |
| windmill-postgres  | -     | none (systemd-windmill-postgres:5432) |
| notebook (JupyterLab+marimo) | 3118 | loopback (token file auth; tailnet door LIVE: svc:notebook -> https://notebook.<tailnet>.ts.net) |

Pipeline (pipeline group, plan docs/agentic-pipeline-plan.md, added 2026-11-10):

| service            | port  | binding  |
|--------------------|-------|----------|
| forge (Forgejo web) | 3120 | loopback (tailnet door: svc:forge -> https://forge.<tailnet>.ts.net) |
| forge git SSH      | 2223  | 0.0.0.0 (LAN-reachable: host carries no nft ruleset; flagged at enable; tailnet clients use ssh://git@<node-tailnet-fqdn>:2223). SSH host keys in named volume forge-ssh |
| s3 (Garage)        | 3121  | loopback (svc:s3 door optional; host CLIs use 127.0.0.1:3121; in-network systemd-s3:3900) |
| concourse-web      | 3122  | loopback (tailnet door: svc:concourse -> https://concourse.<tailnet>.ts.net; TSA :2222 in-network only) |
| concourse-worker   | -     | none (privileged; reaches TSA via systemd-concourse-web:2222) |
| concourse-postgres | -     | none (systemd-concourse-pg:5432) |
| forge-postgres     | -     | none (systemd-forge-pg:5432) |
| concourse-mcp      | 3123  | loopback (Hermes host MCP); in-network systemd-concourse-mcp:8080/mcp for task containers |

2222 is free on this host (plan sec.4 probe); the concourse TSA never
publishes a host port. 3100-3119 pre-owned, 3120-3123 taken here.

Tailnet doors for the KB (tailscale serve; real FQDN never committed):
ragflow -> `https://ai.<tailnet>.ts.net:8444`,
lightrag (`X-API-Key` auth enabled) -> `:8446`. (The n8n door `:8445`
was removed with the teardown.)

Tailscale Services (subdomain doors; migration one service at a time per
owner directive 2026-11-05, sketchlab first; svc:windmill + svc:notebook
added 2026-11-05):
`svc:sketchlab` -> `https://sketchlab.<tailnet>.ts.net` (port 443 per
service VIP; no port suffix). Setup verified live:
1. node must be a TAGGED device: `tailscale up --advertise-tags=tag:server
   --hostname=ai` + policy `"tagOwners": {"tag:server": ["autogroup:owner"]}`
   (browser login once; existing per-node serve doors keep working)
2. console Services page -> Define Service (name `sketchlab`, port 443)
3. policy auto-approver: `"autoApprovers": {"services": {"svc:sketchlab":
   ["tag:server"]}}`
4. host side: `tailscale serve --service=svc:sketchlab --https=443
   http://127.0.0.1:3102`
Known bug (tailscale/tailscale#18821, open Feb 2026): after approval the
daemon may keep saying "approval required" until `tailscale serve clear
svc:<name>` + a few seconds + re-advertise. Verify via
`tailscale status --json` Self.CapMap."service-host" (shows the VIP).
The old serve-port door for sketchlab (:8447) is retired.

Monitoring (added 2026-10-08, plan ~/Documents/plans/ai-lab-monitoring-plan.md):

| service            | port  | binding  |
|--------------------|-------|----------|
| grafana            | 3106  | LAN, login |
| prometheus UI      | 3107  | loopback |
| node-exporter      | 9100  | loopback (Network=host) |
| gpu-exporter       | 9835  | loopback |
| podman-exporter    | 9882  | loopback |
| blackbox-exporter  | 9115  | loopback |
| victorialogs       | 9428  | loopback (debug; Grafana uses ai.network DNS) |
| fluent-bit         | 2020  | loopback (its /api health) |

Caddy files keep their old 3001-3005 TLS front ports: kept for reference
only, never deployed.

## Implementation (Phases 2-5)

1. `services.json` at repo root: name, unit, container, host_port,
   container_port, bind, health, tier, image, boot. Sole source of truth.
2. Quadlets + templates: new PublishPorts; extra-router formula fixed to
   11438+INDEX; open-webui WEBUI_URL/CORS follow 3100; dsh DSH_PORT +
   TRUSTED_HOSTS follow 3105.
3. install.sh / detect-gpus.sh / README / docs: ports updated
   to the scheme (install.sh keeps its structure; registry-driven rewrite
   is a follow-up).
4. `scripts/ai-lab` CLI: status/start/stop/toggle/info, reads
   services.json, JSON output for the plugin.
5. Ryoku plugin `ailab` (topbarGlyph + panel): polls `ai-lab status --json`,
   toggles via `ai-lab toggle <name>`; installed with `ryoku plugin add`.

## Verification

- Every service answers on its new port after restart.
- Boot-enablement unchanged (research stays stopped, opt-ins stay out).
- `ai-lab status` agrees with `systemctl --user list-units`.
- `ryoku plugin validate` clean; widget visible on the bar.

## Additions (2026-11-10, mac-quadlet-widget plan)

| service    | port  | binding + door |
|------------|-------|----------------|
| ailab-api  | 3119  | 127.0.0.1 only (Network=host quadlet, no PublishPort); tailnet door `tailscale serve --https=8448` -> https://ai.<tailnet>.ts.net:8448 (LE cert); bearer token. Control plane consumed by the macOS menu-bar widget. |
