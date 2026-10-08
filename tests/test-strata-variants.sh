#!/usr/bin/env bash
# Strata variants: exactly one may run, nothing starts at boot.
# Every quadlets/strata-*.container.in must
#   - be registered in services.json under group "strata" with boot=false,
#   - share ContainerName=systemd-strata and the registry's PublishPort,
#   - list in Conflicts= every sibling variant and every registry service on
#     its card(s) (the systemd backstop for the GPU rules; gpu-arbiter.py does
#     the moving),
#   - have no [Install] section and no network-online.target dependency,
#   - pin GPUs by UUID placeholder only (no index-based CDI names).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REG="$ROOT/services.json"
fail=0
err() { echo "  FAIL: $*"; fail=1; }

mapfile -t members < <(python3 -c "
import json, sys
for s in json.load(open('$REG'))['services']:
    if s.get('group') == 'strata':
        print(s['name'], s['variant'], str(s['boot']).lower())")
[ "${#members[@]}" -eq 3 ] || err "expected 3 strata variants in services.json, got ${#members[@]}"

for m in "${members[@]}"; do
    read -r name variant boot <<<"$m"
    f="$ROOT/quadlets/$name.container.in"
    [ -f "$f" ] || { err "$name: missing $f"; continue; }
    [ "$boot" = false ] || err "$name: boot must be false in services.json"
    grep -qx 'ContainerName=systemd-strata' "$f" || err "$name: ContainerName is not systemd-strata"
    grep -q '^\[Install\]' "$f" && err "$name: has an [Install] section (must not start at boot)"
    grep -q 'network-online.target' "$f" && err "$name: depends on network-online.target"
    grep -Eq '^AddDevice=nvidia.com/gpu=(all|[0-9]+)$' "$f" && err "$name: CDI device by index/all, pin by UUID"
    grep -q "Volume=%h/.local/share/strata/config-$variant:/data/config" "$f" \
        || err "$name: config volume is not config-$variant"
    conflicts=$(sed -n 's/^Conflicts=//p' "$f")
    for other in "${members[@]}"; do
        read -r oname _ _ <<<"$other"
        [ "$oname" = "$name" ] && continue
        [[ " $conflicts " == *" $oname.service "* ]] || err "$name: Conflicts= lacks $oname.service"
    done
    while read -r unit; do
        [[ " $conflicts " == *" $unit "* ]] || err "$name: shares a card with $unit but Conflicts= lacks it"
    done < <(python3 - "$REG" "$name" <<'EOF'
import json, sys
svcs = json.load(open(sys.argv[1]))["services"]
cards = lambda s: {"5090", "4070ti"} if s.get("gpu") == "both" else ({s["gpu"]} if s.get("gpu") else set())
me = next(s for s in svcs if s["name"] == sys.argv[2])
for s in svcs:
    if s["name"] != me["name"] and s.get("group") != "strata" and cards(s) & cards(me):
        print(s["unit"])
EOF
)
    # The variant's devices must match its registry card(s).
    case "$variant" in
        5090)   want_dev="__GPU_5090_UUID__" ;;
        4070ti) want_dev="__GPU_4070TI_UUID__" ;;
        both)   want_dev="__GPU_5090_UUID__ __GPU_4070TI_UUID__" ;;
    esac
    have_dev=$(sed -n 's/^AddDevice=nvidia.com\/gpu=//p' "$f" | xargs)
    [ "$have_dev" = "$want_dev" ] || err "$name: devices '$have_dev' != '$want_dev'"
done

if [ "$fail" = 0 ]; then
    echo "Strata variants passed."
else
    exit 1
fi
