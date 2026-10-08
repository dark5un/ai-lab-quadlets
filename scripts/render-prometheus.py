#!/usr/bin/env python3
"""render-prometheus.py — generate the monitoring configs from services.json.

The registry is the single source of truth: registering a service is what
puts it under monitoring. Writes (mode 600 files, 700 dirs):

  ~/.config/containers/config/prometheus/prometheus.yml
  ~/.config/containers/config/prometheus/targets/*.json   (file_sd)
  ~/.config/containers/config/prometheus/secrets/         (bearer keys)
  ~/.config/containers/config/blackbox/blackbox.yml
  ~/.config/containers/config/fluent-bit/fluent-bit.conf

Scrape rules (docs/plans: ai-lab-monitoring-plan.md):
  strata / coder   :8080/metrics, bearer = the strata API key.
  llama.cpp        router /metrics needs ?model=X&autoload=false (bare
                   returns 400 on b11459; verified 2026-10-08). http_sd
                   from scripts/llama-sd.py lists only LOADED models, so
                   a scrape can never autoload or keep a model resident.
  comfyui          the baked-in exporter node serves /metrics on 8188.
  rizzo            no /metrics (verified 404): blackbox only.
  everything else  blackbox HTTP probe of its registry health URL.
  node/gpu/podman  the exporters themselves.
  ailab            recording rules over podman-exporter container state
                   (label map built from the registry here).

Run from install.sh; safe to re-run (atomic overwrite).
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
CONF = os.path.join(os.environ.get("AI_LAB_CONFIG_DIR")
                    or os.path.join(os.path.expanduser("~"),
                                    ".config/containers/config"))
REG = json.load(open(os.path.join(ROOT, "services.json")))

CONTAINER_PORT = "systemd-{name}:{port}"


def container_dns(svc):
    """host:port for Prometheus reaching the service over ai.network."""
    base = svc["container"].replace("systemd-", "")
    return f"systemd-{base}:{svc['container_port']}"


def env_get(path, key):
    if not os.path.exists(path):
        return None
    val = None
    for ln in open(path):
        if ln.startswith(key + "="):
            val = ln.split("=", 1)[1].strip()
    return val


def w(path, content, mode=0o600):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    os.chmod(os.path.dirname(path), 0o700)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(content)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


svcs = {s["name"]: s for s in REG["services"]}
strata_key = env_get(os.path.join(CONF, "strata/service.env"), "API_KEY")
llama_key_file = os.path.join(CONF, "llama-cpp/keys.txt")
llama_key = None
if os.path.exists(llama_key_file):
    for ln in open(llama_key_file):
        ln = ln.strip()
        if ln and not ln.startswith("#"):
            llama_key = ln
            break

# ── secrets for bearer auth (mounted read-only into prometheus) ─────────
secrets = {}
if strata_key:
    secrets["strata-api-key"] = strata_key
if llama_key:
    secrets["llama-cpp-api-key"] = llama_key
for name, val in secrets.items():
    w(os.path.join(CONF, "prometheus/secrets", name), val + "\n")

# ── file_sd targets ─────────────────────────────────────────────────────
targets = {}


def add(job, host, labels):
    for t in targets.setdefault(job, []):
        if host in t["targets"]:
            return  # variants share a container name: one target only
    targets[job].append({"targets": [host], "labels": labels})


for s in REG["services"]:
    tier, grp = s["tier"], s.get("group", "")
    if grp in ("strata", "coder"):
        # variants share container name + port: one target per container,
        # the live variant comes from the ailab state metric (join in PromQL).
        add("strata", container_dns(s), {"ai_service": s["container"]})
    elif grp == "llama-cpp":
        # /metrics needs ?model=X&autoload=false (bare returns 400 on
        # b11459; verified 2026-10-08: an unloaded model answers 400
        # WITHOUT loading it, and our routers set no idle/sleep timer,
        # so scraping cannot keep anything resident). One target per
        # model in the card's dir; unloaded models show up=0, which the
        # dashboards filter by the presence of data.
        card = s.get("gpu", "")
        mdir = os.path.join(os.path.expanduser("~"),
                            ".local/share/llama.cpp/cards", card)
        if os.path.isdir(mdir):
            for m in sorted(os.listdir(mdir)):
                if os.path.isdir(os.path.join(mdir, m)):
                    add("llama-cpp", container_dns(s),
                        {"ai_service": s["name"], "llama_model": m})
    elif grp == "comfyui":
        add("comfyui", container_dns(s), {"ai_service": s["container"]})
    elif tier == "monitoring":
        pass  # exporters are scraped statically; grafana/prometheus self-scrape below

# exporters
add("node", "host.containers.internal:9100", {})
add("gpu", "systemd-gpu-exporter:9835", {})
add("podman", "systemd-podman-exporter:9882", {})
add("blackbox", "systemd-blackbox-exporter:9115", {})
add("prometheus", "systemd-prometheus:9090", {})
add("victorialogs", "systemd-victorialogs:9428", {"metrics_path": "/metrics"})

os.makedirs(os.path.join(CONF, "prometheus/targets"), exist_ok=True)
os.chmod(os.path.join(CONF, "prometheus/targets"), 0o700)
for job, tgs in targets.items():
    w(os.path.join(CONF, "prometheus/targets", f"{job}.json"),
      json.dumps(tgs, indent=1), mode=0o644)

# ── blackbox probes: every service's health URL over ai.network ────────
bb_modules = {"http_2xx": {"prober": "http",
                           "headers": {"Accept": "text/plain"},
                           "preferred_ip_protocol": "ip4",
                           "valid_http_status_codes": [200, 201, 202, 204, 301, 302, 304, 401, 403]}}
probe_targets = []
for s in REG["services"]:
    if s["tier"] == "monitoring" and s["name"] != "grafana":
        continue
    path = s["health"]
    probe_targets.append({"targets": [f"http://{container_dns(s)}{path}"],
                          "labels": {"ai_service": s["name"]}})
w(os.path.join(CONF, "blackbox/blackbox.yml"),
  json.dumps({"modules": bb_modules}, indent=1).replace('"modules"', "modules")
  .replace('{\n  "prober"', "prober"), mode=0o644) if False else None
# YAML by hand (no yaml dep guaranteed on the host):
lines = ["modules:"]
for k, v in bb_modules.items():
    lines.append(f"  {k}:")
    lines.append(f"    prober: {v['prober']}")
    lines.append("    timeout: 5s")
    lines.append("    http:")
    lines.append("      preferred_ip_protocol: ip4")
    lines.append("      valid_http_status_codes: [200, 201, 202, 204, 301, 302, 304, 401, 403]")
w(os.path.join(CONF, "blackbox/blackbox.yml"), "\n".join(lines) + "\n", mode=0o644)
w(os.path.join(CONF, "prometheus/targets", "blackbox-probes.json"),
  json.dumps(probe_targets, indent=1), mode=0o644)

# ── ailab state: container name -> service/gpu/variant label map ──────
# rendered as a recording-rule-friendly file_sd-free map: the rules use
# podman_container_state{name=...}; we join via a metric relabel from a
# generated static map exposed as a textfile collector instead. Simplest
# robust form: one `ailab_service_info` line per service via node-exporter
# textfile dir.
textfile = os.path.join(os.environ.get("HOME", ""), ".local/share/node-exporter/textfile")
os.makedirs(textfile, exist_ok=True)
# One row per CONTAINER (variants of strata/comfyui/coder share a container
# name and can never run at the same time): service = the group for shared
# containers, the name otherwise. The live strata variant comes from
# strata:engine_max_context / model_name on the scrape itself.
by_container = {}
for s in REG["services"]:
    by_container.setdefault(s["container"], []).append(s)
rows = []
for cname, group in sorted(by_container.items()):
    svc = group[0]["name"] if len(group) == 1 else group[0].get("group", group[0]["name"])
    gpu = group[0].get("gpu", "")
    tier = group[0]["tier"]
    port = group[0]["host_port"]
    variants = "|".join(g.get("variant", g["name"]) for g in group)
    rows.append(
        f'ailab_service_info{{service="{svc}",container="{cname}",'
        f'gpu="{gpu}",tier="{tier}",port="{port}",variants="{variants}"}} 1')
w(os.path.join(textfile, "ailab.prom"), "\n".join(rows) + "\n", mode=0o644)

# ── prometheus.yml ──────────────────────────────────────────────────────
def auth_block(keyfile):
    if not keyfile:
        return ""
    return ("    authorization:\n"
            "      type: Bearer\n"
            f"      credentials_file: /etc/prometheus/secrets/{keyfile}\n")


jobs = []
jobs.append("""  - job_name: strata
    scrape_interval: 15s
    metrics_path: /metrics
""" + auth_block("strata-api-key" if strata_key else None) + """    file_sd_configs:
      - files: [/etc/prometheus/targets/strata.json]
""")
jobs.append("""  - job_name: llama-cpp
    scrape_interval: 15s
    metrics_path: /metrics
    params:
      autoload: ["false"]
""" + auth_block("llama-cpp-api-key" if llama_key else None) + """    file_sd_configs:
      - files: [/etc/prometheus/targets/llama-cpp.json]
        refresh_interval: 60s
    relabel_configs:
      # file_sd carries a llama_model label; __param_model (the query
      # param) must come from a relabel, not from file_sd directly.
      - source_labels: [llama_model]
        target_label: __param_model
      - source_labels: [llama_model]
        target_label: model
""")
jobs.append("""  - job_name: comfyui
    scrape_interval: 15s
    metrics_path: /metrics
    file_sd_configs:
      - files: [/etc/prometheus/targets/comfyui.json]
""")
jobs.append("""  - job_name: blackbox
    metrics_path: /probe
    params:
      module: [http_2xx]
    file_sd_configs:
      - files: [/etc/prometheus/targets/blackbox-probes.json]
        refresh_interval: 60s
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: systemd-blackbox-exporter:9115
""")
jobs.append("""  - job_name: exporters
    file_sd_configs:
      - files: [/etc/prometheus/targets/node.json, /etc/prometheus/targets/gpu.json,
                /etc/prometheus/targets/podman.json, /etc/prometheus/targets/blackbox.json,
                /etc/prometheus/targets/prometheus.json, /etc/prometheus/targets/victorialogs.json]
        refresh_interval: 60s
""")

otlp = "otlp:\n  promote_resource_attributes: [service.name]\n"
prom_cfg = f"""# Generated by scripts/render-prometheus.py from services.json — do not edit.
global:
  scrape_interval: 30s
  external_labels:
    stack: ai-lab

storage:
  tsdb:
    out_of_order_time_window: 30m

{otlp}
scrape_configs:
{''.join(jobs)}
rule_files:
  - /etc/prometheus/rules/*.yml
"""
w(os.path.join(CONF, "prometheus/prometheus.yml"), prom_cfg, mode=0o644)

# ── recording rules: ailab:service_running from podman state + info ───
rules = """# Generated by scripts/render-prometheus.py — do not edit.
groups:
  - name: ailab-state
    interval: 15s
    rules:
      # podman_container_state carries id (not name): join state -> info to
      # get the container name, then the registry map (from the node
      # textfile collector) for service/gpu/variant/tier labels.
      - record: ailab:service_running
        expr: >
          (podman_container_state == 2)
          * on(id) group_left(name) podman_container_info
          * on(name) group_left(service, gpu, tier, variants)
          (label_replace(ailab_service_info > 0, "name", "$1", "container", "(.*)"))
"""
os.makedirs(os.path.join(CONF, "prometheus/rules"), exist_ok=True)
os.chmod(os.path.join(CONF, "prometheus/rules"), 0o700)
w(os.path.join(CONF, "prometheus/rules", "ailab.yml"), rules, mode=0o644)

# ── fluent-bit.conf ─────────────────────────────────────────────────────
fb = """# Generated by scripts/render-prometheus.py — do not edit.
[SERVICE]
    Flush 2
    log_level info
    HttpServer On
    Http_Server_Port 2020

[INPUT]
    Name systemd
    Path /var/log/journal
    Systemd_Filter _UID=1000
    Read_From_Tail false
    DB /db/journal.db
    Tag journal

[FILTER]
    Name modify
    Match journal
    Rename CONTAINER_NAME stream
    Rename PRIORITY priority

[OUTPUT]
    Name http
    Match journal
    Host systemd-victorialogs
    Port 9428
    URI /insert/jsonline?_stream_fields=stream,priority&_msg_field=MESSAGE&_time_field=t
    format json_lines
    header Content-Type application/json
"""
w(os.path.join(CONF, "fluent-bit/fluent-bit.conf"), fb, mode=0o644)

print(f"rendered monitoring configs into {CONF}")
print(f"  prometheus: {len(targets)+1} file_sd target groups, {len(probe_targets)} blackbox probes")
print(f"  secrets: {', '.join(secrets) or 'none'}")
