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
[ "${#members[@]}" -eq 7 ] || err "expected 7 strata variants in services.json, got ${#members[@]}"

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
        5090*)  want_dev="__GPU_5090_UUID__" ;;
        4070ti*) want_dev="__GPU_4070TI_UUID__" ;;
        both)   want_dev="__GPU_5090_UUID__ __GPU_4070TI_UUID__" ;;
    esac
    have_dev=$(sed -n 's/^AddDevice=nvidia.com\/gpu=//p' "$f" | xargs)
    [ "$have_dev" = "$want_dev" ] || err "$name: devices '$have_dev' != '$want_dev'"
    # 5090 variants run beside strata-coder: pinned, and context per variant.
    case "$variant" in
        5090*)
            grep -qx 'Entrypoint=/usr/bin/taskset' "$f" && grep -qx 'Exec=-c __CPUS_MAIN__ ./docker-entrypoint.sh' "$f" \
                || err "$name: not pinned to __CPUS_MAIN__"
            ;;
    esac
    # Context per variant: the suffix names it (none = 256K).
    case "$variant" in *-524k) ctx=524288 ;; *-1m) ctx=1048576 ;; *) ctx=262144 ;; esac
    grep -qx "Environment=CONTEXT=$ctx" "$f" || err "$name: CONTEXT is not $ctx"
    case "$variant" in 4070ti*|both)
        for c in strata-coder strata-coder-524k strata-coder-1m; do
            [[ " $conflicts " == *" $c.service "* ]] || err "$name: Conflicts= lacks $c.service"
        done ;;
    esac
done

# The coder group (strata-coder 256K, -524k, -1m): beside the strata group,
# owns the 4070 Ti, own name/port; one coder variant at a time.
mapfile -t coders < <(python3 -c "
import json
for s in json.load(open('$REG'))['services']:
    if s.get('group') == 'coder':
        print(s['name'], s['variant'], s['host_port'], str(s['boot']).lower(), str(s.get('owns_card')).lower(), s['gpu'])")
[ "${#coders[@]}" -eq 3 ] || err "expected 3 coder variants in services.json, got ${#coders[@]}"
for m in "${coders[@]}"; do
    read -r name variant cport cboot cowns cgpu <<<"$m"
    f="$ROOT/quadlets/$name.container.in"
    [ -f "$f" ] || { err "$name: missing $f"; continue; }
    [ "$cboot" = false ] || err "$name: boot must be false"
    [ "$cowns" = true ] || err "$name: owns_card must be true"
    [ "$cgpu" = 4070ti ] || err "$name: gpu must be 4070ti"
    grep -qx 'ContainerName=systemd-strata-coder' "$f" || err "$name: ContainerName"
    grep -qx "PublishPort=0.0.0.0:$cport:8080/tcp" "$f" || err "$name: PublishPort != registry $cport"
    grep -qx 'AddDevice=nvidia.com/gpu=__GPU_4070TI_UUID__' "$f" || err "$name: device"
    grep -qx 'Exec=-c __CPUS_CODER__ ./docker-entrypoint.sh' "$f" || err "$name: not pinned to __CPUS_CODER__"
    cfg="config-${variant}"
    grep -q "Volume=%h/.local/share/strata/$cfg:/data/config" "$f" || err "$name: config volume is not $cfg"
    case "$variant" in *-524k) ctx=524288 ;; *-1m) ctx=1048576 ;; *) ctx=262144 ;; esac
    grep -qx "Environment=CONTEXT=$ctx" "$f" || err "$name: CONTEXT is not $ctx"
    grep -q '^\[Install\]' "$f" && err "$name: has [Install]"
    conflicts=$(sed -n 's/^Conflicts=//p' "$f")
    for u in strata-4070ti strata-4070ti-524k strata-4070ti-1m strata-both llama-cpp-4070ti rizzo comfyui-4070ti llama-cpp-both; do
        [[ " $conflicts " == *" $u.service "* ]] || err "$name: Conflicts= lacks $u.service"
    done
    for other in "${coders[@]}"; do
        read -r oname _ <<<"$other"
        [ "$oname" = "$name" ] && continue
        [[ " $conflicts " == *" $oname.service "* ]] || err "$name: Conflicts= lacks sibling $oname.service"
    done
    for u in strata-5090 strata-5090-524k strata-5090-1m; do
        [[ " $conflicts " == *" $u.service "* ]] && err "$name: must not conflict with $u.service (duo)"
    done
done

if [ "$fail" = 0 ]; then
    echo "Strata variants passed."
else
    exit 1
fi
