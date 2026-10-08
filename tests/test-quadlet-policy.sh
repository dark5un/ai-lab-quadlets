#!/usr/bin/env bash
# Quadlet policy for every repo quadlet and registry entry:
#   - nothing starts at boot: no [Install], registry boot=false everywhere
#   - no network-online.target dependency (podman's waiter hangs on Arch)
#   - units on ai.network Want + start After ai-network.service
#   - no hardcoded GPU UUID (templates carry placeholders only)
#   - every non-strata GPU service pins with AddDevice=nvidia.com/gpu=all +
#     CUDA_VISIBLE_DEVICES matching its registry card(s); services without a
#     card get no GPU at all
# (strata variants are covered by test-strata-variants.sh)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
err() { echo "  FAIL: $*"; fail=1; }

for f in "$ROOT"/quadlets/*.container "$ROOT"/quadlets/*.container.in; do
    n="$(basename "$f")"
    grep -q '^\[Install\]' "$f" && err "$n has an [Install] section"
    grep -q 'network-online.target' "$f" && err "$n depends on network-online.target"
    grep -Eq 'GPU-[0-9a-f]{8}-' "$f" && err "$n hardcodes a GPU UUID (use __GPU_*_UUID__)"
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
bad = 0
for s in json.load(open(f"{root}/services.json"))["services"]:
    name = s["name"]
    if s["boot"] is not False:
        print(f"  FAIL: {name}: registry boot must be false"); bad = 1
    if s.get("group") == "strata":
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
        print(f"  FAIL: {name}: has GPU devices but no registry card"); bad = 1
sys.exit(bad)
EOF

[ "$fail" = 0 ] && echo "Quadlet policy passed." || exit 1
