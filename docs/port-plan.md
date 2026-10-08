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
| sketchlab          | 3004 | 3102 | LAN      |
| hyperframes        | 3006 | 3103 | LAN      |
| hermes (opt-in)    | 3003 | 3104 | LAN      |
| deepseek-harness   | 3080 | 3105 | loopback (Network=host, dsh binds 127.0.0.1 itself) |

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
