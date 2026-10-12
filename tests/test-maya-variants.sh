#!/usr/bin/env bash
# Maya variants: exactly one may run and every variant is fully exclusive —
# starting any maya stops every strata instance (and vice versa), so every
# quadlets/maya-*.container.in must
#   - be registered in services.json under group "maya" with boot=false,
#     exclusive=true, gpu "5090" or "both" (never 4070ti: S-packs need >12 GB),
#   - share ContainerName=systemd-maya and the registry's PublishPort,
#   - list in Conflicts= every sibling variant, every legacy maya unit, every
#     strata variant, every strata-owning coder, and every registry service on
#     its card(s),
#   - have no [Install] section and no network-online.target dependency,
#   - pin GPUs by UUID placeholder only (no index-based CDI names),
#   - exec a per-context config (maya-maya-<card>-<ctx>.json) with the
#     context matching its variant name,
#   - and the six per-context configs must exist in the maya checkout with
#     the same --max-context.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REG="$ROOT/services.json"
MAYA="${MAYA_REPO:-$HOME/src/project-maya}"
fail=0
err() { echo "  FAIL: $*"; fail=1; }

mapfile -t members < <(python3 -c "
import json, sys
for s in json.load(open('$REG'))['services']:
    if s.get('group') == 'maya':
        print(s['name'], s['variant'], s['host_port'], str(s['boot']).lower(), str(s.get('exclusive')).lower(), s['gpu'])")
[ "${#members[@]}" -eq 6 ] || err "expected 6 maya variants in services.json, got ${#members[@]}"

for m in "${members[@]}"; do
    read -r name variant cport cboot cexcl cgpu <<<"$m"
    f="$ROOT/quadlets/$name.container.in"
    [ -f "$f" ] || { err "$name: missing $f"; continue; }
    [ "$cboot" = false ] || err "$name: boot must be false"
    [ "$cexcl" = true ] || err "$name: exclusive must be true"
    case "$cgpu" in 5090|both) ;; *) err "$name: gpu must be 5090 or both (never 4070ti)";; esac
    grep -qx 'ContainerName=systemd-maya' "$f" || err "$name: ContainerName"
    grep -qx "PublishPort=0.0.0.0:$cport:8080/tcp" "$f" || err "$name: PublishPort != registry $cport"
    grep -q 'network-online.target' "$f" && err "$name: depends on network-online.target"
    grep -Eq '^AddDevice=nvidia.com/gpu=([0-9]+)$' "$f" && err "$name: CDI device by index"
    grep -q '^\[Install\]' "$f" && err "$name: has an [Install] section (must not start at boot)"
    # devices: the house policy for non-strata GPU services (all + CUDA_VISIBLE_DEVICES
    # by UUID, matching the registry card(s); test-quadlet-policy.sh checks the rest)
    case "$variant" in
        5090*) want_cvd="__GPU_5090_UUID__" ;;
        both*) want_cvd="__GPU_5090_UUID__,__GPU_4070TI_UUID__" ;;
    esac
    have_cvd=$(sed -n 's/^Environment=CUDA_VISIBLE_DEVICES=//p' "$f")
    [ "$have_cvd" = "$want_cvd" ] || err "$name: CUDA_VISIBLE_DEVICES '$have_cvd' != '$want_cvd'"
    # the config it execs matches the variant's context
    case "$variant" in
        *-256)  ctx=262144 ;; *-512) ctx=524288 ;; *-1024) ctx=1048576 ;;
    esac
    grep -qx "Exec=-c 0-23 /opt/maya/.venv/bin/python /opt/maya/maya.py --config /opt/maya/maya-maya-$variant.json --port 8080 --host 0.0.0.0" "$f" \
        || err "$name: Exec is not the maya-maya-$variant.json config"
    grep -qx "Volume=%h/src/project-maya:/opt/maya:Z" "$f" || err "$name: repo volume missing"
    grep -qx "Volume=%h/.local/share/maya/models:/opt/maya-data/models:Z" "$f" || err "$name: models volume missing"
    # full exclusivity: every sibling + legacy + strata group + coder group + card peers
    conflicts=$(sed -n 's/^Conflicts=//p' "$f")
    for other in "${members[@]}"; do
        read -r oname _ _ _ _ <<<"$other"
        [ "$oname" = "$name" ] && continue
        [[ " $conflicts " == *" $oname.service "* ]] || err "$name: Conflicts= lacks sibling $oname.service"
    done
    for legacy in maya-both maya-5090; do
        [[ " $conflicts " == *" $legacy.service "* ]] || err "$name: Conflicts= lacks legacy $legacy.service"
    done
    while read -r u; do
        [[ " $conflicts " == *" $u "* ]] || err "$name: Conflicts= lacks strata/coder $u"
    done < <(python3 -c "
import json, sys
for s in json.load(open('$REG'))['services']:
    if s.get('group') in ('strata', 'coder'):
        print(s['unit'])")
    # every registry service that shares a card with this variant
    while read -r unit; do
        [[ " $conflicts " == *" $unit "* ]] || err "$name: shares a card with $unit but Conflicts= lacks it"
    done < <(python3 - "$REG" "$name" <<'EOF'
import json, sys
svcs = json.load(open(sys.argv[1]))["services"]
cards = lambda s: {"5090", "4070ti"} if s.get("gpu") == "both" else ({s["gpu"]} if s.get("gpu") else set())
me = next(s for s in svcs if s["name"] == sys.argv[2])
for s in svcs:
    if s["name"] != me["name"] and s.get("group") != "maya" and cards(s) & cards(me):
        print(s["unit"])
EOF
)
done

# per-context configs in the maya checkout
for v in 5090-256 5090-512 5090-1024 both-256 both-512 both-1024; do
    cfg="$MAYA/maya-maya-$v.json"
    [ -f "$cfg" ] || { err "missing $cfg"; continue; }
    case "$v" in *-256) ctx=262144 ;; *-512) ctx=524288 ;; *-1024) ctx=1048576 ;; esac
    actual=$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
a = d.get('args') or []
print(a[a.index('--max-context') + 1] if '--max-context' in a else '?')" "$cfg")
    [ "$actual" = "$ctx" ] || err "$cfg: --max-context '$actual' != $ctx"
done

if [ "$fail" = 0 ]; then
    echo "Maya variants passed."
else
    exit 1
fi
