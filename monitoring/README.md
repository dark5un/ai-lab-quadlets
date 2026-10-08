# Monitoring assets

Everything here is mounted read-only into the grafana container by
quadlets/grafana.container and provisioned from
provisioning/dashboards/ai-lab.yml. Edit in git, `ai-lab restart grafana`
(or wait for the 30 s update interval) to apply.

## dashboards/ — sources and revisions (vendored 2026-10-08)

| file | source | notes |
|---|---|---|
| ailab-overview.json | ours | mode timeline, per-card GPU, RAM, tok/s, health grid, logs |
| grafana-strata.json | Strata upstream docs/monitoring/grafana-strata.json | vLLM + strata:* panels |
| llamacpp-routers.json | ours | llamacpp:* per router + model |
| open-webui.json | ours | OTLP metrics pushed into Prometheus |
| comfyui.json | ours | from the baked-in comfyui-prometheus-exporter node |
| node-exporter-full.json | grafana.com dashboard 1860 rev 38 | |
| nvidia-gpu-metrics.json | grafana.com dashboard 14574 rev 15 | |
| nvidia-gpu-overview.json | grafana.com dashboard 25547 rev 3 | |
| podman-exporter.json | grafana.com dashboard 21559 rev 1 | |

Vendoring rule: community dashboards had `__inputs`/`__requires` stripped
and every datasource reference pinned to uid `prometheus` (the uid set in
provisioning/datasources/ai-lab.yml), so they import without the import
wizard. When re-vendoring, repeat that substitution and update the
revision number above.

## Generated, not here

prometheus.yml, file_sd targets, blackbox.yml and fluent-bit.conf are
generated from services.json by scripts/render-prometheus.py into
~/.config/containers/config/ — see README "Monitoring".
