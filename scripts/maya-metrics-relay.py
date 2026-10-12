#!/usr/bin/env python3
"""maya-metrics-relay.py — turn Project Maya's JSON /metrics into text format.

Maya's serve/server.py answers /metrics with a JSON blob (the Monitor tab's
payload), not Prometheus text. This relay fetches it from the host loopback
(port 11440, the registry's maya port), extracts the serving numbers, and
writes ~/.local/share/node-exporter/textfile/maya.prom, which node-exporter's
textfile collector exposes as the `node` job. Run by maya-metrics-relay.timer
(user unit, every 15 s); a stopped maya leaves no file (stale series vanish).

Metrics (all maya: prefixed, gauge unless noted):
  maya:up                       1 when /metrics answered
  maya:engine_max_context       the engine's context window
  maya:live_state               1 for the live state label (idle|generating|...)
  maya:live_tok_s               decode tok/s of the running sequence
  maya:tier_tok_s               last tier sample: tok/s
  maya:tier_vram_hit            expert VRAM hit ratio
  maya:tier_ram_fetch           experts fetched from RAM per token
  maya:totals_requests          counter (since engine start)
  maya:totals_prompt_tokens     counter
  maya:totals_output_tokens     counter
  maya:totals_prompt_ms         counter
  maya:totals_decode_ms         counter
  maya:gpu_mem_used_bytes / maya:gpu_mem_total_bytes  (sum over the cards)
  maya:gpu_util_percent
  maya:ram_used_bytes / maya:ram_total_bytes
  maya:info                     constant, labels: model, kv, maya_version
"""
import json
import os
import sys
import urllib.request

PORT = os.environ.get("MAYA_RELAY_PORT", "11440")
OUT = os.path.join(os.environ.get("HOME", ""),
                   ".local/share/node-exporter/textfile/maya.prom")


def main():
    rows = []
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/metrics", timeout=5) as r:
            m = json.load(r)
    except Exception:
        # maya down: remove the file so the series go stale, not frozen
        try:
            os.remove(OUT)
        except OSError:
            pass
        return 0

    eng, live, tier, tot = m.get("engine", {}), m.get("live", {}), (m.get("tiers") or {}).get("now", {}), m.get("totals", {})
    hw = m.get("hardware", {})
    rows.append('maya:up 1')
    rows.append(f'maya:info{{model="{eng.get("model", "?")}",kv="{eng.get("kv", "?")}",maya_version="{eng.get("maya_version", "?")}"}} 1')
    if eng.get("max_context") is not None:
        rows.append(f'maya:engine_max_context {eng["max_context"]}')
    state = live.get("state") or "off"
    rows.append(f'maya:live_state{{state="{state}"}} 1')
    for key, metric in (("tok_s", "maya:live_tok_s"),):
        if live.get(key) is not None:
            rows.append(f"{metric} {live[key]}")
    for key, metric in (("tok_s", "maya:tier_tok_s"), ("vram_hit", "maya:tier_vram_hit"),
                        ("ram_fetch", "maya:tier_ram_fetch")):
        if tier.get(key) is not None:
            rows.append(f"{metric} {tier[key]}")
    for key, metric in (("requests", "maya:totals_requests"), ("prompt_tokens", "maya:totals_prompt_tokens"),
                        ("output_tokens", "maya:totals_output_tokens"), ("prompt_ms", "maya:totals_prompt_ms"),
                        ("decode_ms", "maya:totals_decode_ms")):
        if tot.get(key) is not None:
            rows.append(f"{metric} {tot[key]}")
    if hw.get("gpu_mem_used") is not None:
        rows.append(f'maya:gpu_mem_used_bytes {hw["gpu_mem_used"]}')
        rows.append(f'maya:gpu_mem_total_bytes {hw["gpu_mem_total"]}')
        rows.append(f'maya:gpu_util_percent {hw.get("gpu_util", 0)}')
    if hw.get("ram_used") is not None:
        rows.append(f'maya:ram_used_bytes {hw["ram_used"]}')
        rows.append(f'maya:ram_total_bytes {hw["ram_total"]}')

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    tmp = OUT + ".tmp"
    with open(tmp, "w") as f:
        f.write("\n".join(rows) + "\n")
    os.replace(tmp, OUT)   # atomic: the collector never reads a half file
    return 0


if __name__ == "__main__":
    sys.exit(main())
