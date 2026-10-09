#!/usr/bin/env bash
# Quadlet policy for every repo quadlet and registry entry:
#   - nothing starts at boot: no [Install], registry boot=false everywhere,
#     EXCEPT the monitoring tier (plan D1): prometheus, the exporters and the
#     log pair enable at boot; grafana stays on demand like the web apps.
#   - the one GPU exception: strata-4070ti is the default strata variant and
#     boots with the session (its Conflicts= lines stop it when another
#     variant or card user takes over).
#   - no network-online.target dependency (podman's waiter hangs on Arch)
#   - units on ai.network Want + start After ai-network.service
#   - no hardcoded GPU UUID (templates carry placeholders only)
#   - SuccessExitStatus=143 everywhere (a stop must not leave a failed unit)
#   - every non-strata GPU service pins with AddDevice=nvidia.com/gpu=all +
#     CUDA_VISIBLE_DEVICES matching its registry card(s); services without a
#     card get no GPU at all. One whitelist exception: gpu-exporter carries
#     AddDevice for NVML but NO registry gpu field (it must not count as a
#     GPU service for the arbiter).
# (strata variants and strata-coder are covered by test-strata-variants.sh)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
err() { echo "  FAIL: $*"; fail=1; }

for f in "$ROOT"/quadlets/*.container "$ROOT"/quadlets/*.container.in; do
    n="$(basename "$f")"
    if grep -q '^\[Install\]' "$f"; then
        # boot allowed only for the monitoring tier minus grafana, plus the
        # default strata variant
        case "$n" in
            prometheus.container|node-exporter.container|gpu-exporter.container|\
            podman-exporter.container|blackbox-exporter.container|\
            victorialogs.container|fluent-bit.container|strata-4070ti.container.in) ;;
            *) err "$n has an [Install] section" ;;
        esac
    fi
    grep -q 'network-online.target' "$f" && err "$n depends on network-online.target"
    grep -Eq 'GPU-[0-9a-f]{8}-' "$f" && err "$n hardcodes a GPU UUID (use __GPU_*_UUID__)"
    # A SIGTERM-killed container exits 143; without this every stop of such
    # an app leaves the unit "failed".
    grep -qx 'SuccessExitStatus=143' "$f" || err "$n lacks SuccessExitStatus=143"
    if grep -qx 'Network=ai.network' "$f"; then
        grep -qx 'Wants=ai-network.service' "$f" || err "$n lacks Wants=ai-network.service"
        grep -qx 'After=ai-network.service' "$f" || err "$n lacks After=ai-network.service"
    fi
done

python3 - "$ROOT" <<'EOF' || fail=1
import json, os, re, sys
root = sys.argv[1]
want = {"5090": "__GPU_5090_UUID__", "4070ti": "__GPU_4070TI_UUID__",
        "both": "__GPU_5090_UUID__,__GPU_4070TI_UUID__"}
BOOT_OK = {"prometheus", "node-exporter", "gpu-exporter", "podman-exporter",
           "blackbox-exporter", "victorialogs", "fluent-bit", "strata-4070ti"}
GPU_DEVICE_OK = {"gpu-exporter"}   # AddDevice without a registry card
bad = 0
for s in json.load(open(f"{root}/services.json"))["services"]:
    name = s["name"]
    if s["boot"] is not (name in BOOT_OK):
        print(f"  FAIL: {name}: boot={s['boot']} violates the monitoring-tier rule"); bad = 1
    if s.get("group") in ("strata", "coder"):
        continue
    path = next((p for p in (f"{root}/quadlets/{name}.container.in", f"{root}/quadlets/{name}.container")
                 if os.path.exists(p)), None)
    if not path:
        print(f"  FAIL: {name}: no quadlet"); bad = 1; continue
    text = open(path).read()
    devices = re.findall(r"^AddDevice=(.*)$", text, re.M)
    cvd = re.findall(r"^Environment=CUDA_VISIBLE_DEVICES=(.*)$", text, re.M)
    if s.get("gpu"):
        if devices != ["nvidia.com/gpu=all"]:
            print(f"  FAIL: {name}: AddDevice {devices} != ['nvidia.com/gpu=all']"); bad = 1
        if cvd != [want[s["gpu"]]]:
            print(f"  FAIL: {name}: CUDA_VISIBLE_DEVICES {cvd} != registry card {s['gpu']} ({want[s['gpu']]})"); bad = 1
        if s["gpu"] == "both" and not s.get("exclusive"):
            print(f"  FAIL: {name}: a non-strata service on both cards must be exclusive"); bad = 1
    elif devices or cvd:
        if name in GPU_DEVICE_OK and devices == ["nvidia.com/gpu=all"] and not cvd:
            pass  # gpu-exporter: NVML device access, not a card owner
        else:
            print(f"  FAIL: {name}: has GPU devices but no registry card"); bad = 1
sys.exit(bad)
EOF

[ "$fail" = 0 ] && echo "Quadlet policy passed." || exit 1
