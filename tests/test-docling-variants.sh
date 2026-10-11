#!/usr/bin/env bash
# docling variants (docling-cpu, docling-4070ti): exactly one may run; both
# on demand (boot=false). Every quadlets/docling-* must
#   - be registered in services.json under group "docling" with boot=false,
#   - share ContainerName=systemd-docling and PublishPort 127.0.0.1:3108:5001,
#   - list the sibling in Conflicts=,
#   - mount the shared docling-hf cache volume and ~/Documents read-only,
#   - enable the UI, RunInit, SuccessExitStatus=143, no [Install],
#   - the 4070ti variant pins CUDA_VISIBLE_DEVICES=__GPU_4070TI_UUID__ with
#     AddDevice=nvidia.com/gpu=all; the cpu variant gets no GPU at all.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REG="$ROOT/services.json"
fail=0
err() { echo "  FAIL: $*"; fail=1; }

mapfile -t members < <(python3 -c "
import json, sys
for s in json.load(open('$REG'))['services']:
    if s.get('group') == 'docling':
        print(s['name'], s['variant'], str(s['boot']).lower(), s.get('gpu', ''))")
[ "${#members[@]}" -eq 2 ] || err "expected 2 docling variants in services.json, got ${#members[@]}"

for m in "${members[@]}"; do
    read -r name variant boot gpu <<<"$m"
    [ "$boot" = false ] || err "$name: boot must be false"
    f="$ROOT/quadlets/$name.container"
    [ -f "$f" ] || f="$ROOT/quadlets/$name.container.in"
    [ -f "$f" ] || { err "$name: no quadlet"; continue; }
    grep -qx 'ContainerName=systemd-docling' "$f" || err "$name: ContainerName is not systemd-docling"
    grep -qx 'PublishPort=127.0.0.1:3108:5001/tcp' "$f" || err "$name: PublishPort is not 127.0.0.1:3108:5001"
    grep -q '^\[Install\]' "$f" && err "$name: has an [Install] section (must not start at boot)"
    grep -q 'network-online.target' "$f" && err "$name: depends on network-online.target"
    conflicts=$(sed -n 's/^Conflicts=//p' "$f")
    for other in "${members[@]}"; do
        read -r oname _ _ _ <<<"$other"
        [ "$oname" = "$name" ] && continue
        [[ " $conflicts " == *" $oname.service "* ]] || err "$name: Conflicts= lacks $oname.service"
    done
    grep -q 'Volume=docling-hf:/opt/app-root/src/.cache' "$f" || err "$name: docling-hf cache volume missing"
    grep -q 'Volume=%h/Documents:/mnt/documents:ro' "$f" || err "$name: ~/Documents ro mount missing"
    grep -qx 'Environment=DOCLING_SERVE_ENABLE_UI=1' "$f" || err "$name: UI not enabled"
    grep -qx 'Environment=DOCLING_SERVE_MAX_SYNC_WAIT=3600' "$f" \
        || err "$name: sync-wait cap not raised (big books 504 at the 120s default)"
    grep -qx 'RunInit=true' "$f" || err "$name: lacks RunInit=true"
    grep -qx 'SuccessExitStatus=143' "$f" || err "$name: lacks SuccessExitStatus=143"
    case "$variant" in
        4070ti)
            [ "$gpu" = 4070ti ] || err "$name: registry gpu must be 4070ti"
            grep -qx 'AddDevice=nvidia.com/gpu=all' "$f" || err "$name: lacks AddDevice=nvidia.com/gpu=all"
            grep -qx 'Environment=CUDA_VISIBLE_DEVICES=__GPU_4070TI_UUID__' "$f" \
                || err "$name: CUDA_VISIBLE_DEVICES is not the 4070 Ti placeholder"
            ;;
        cpu)
            [ -z "$gpu" ] || err "$name: cpu variant must have no registry gpu"
            grep -q 'AddDevice=' "$f" && err "$name: cpu variant has GPU devices"
            grep -q 'CUDA_VISIBLE_DEVICES' "$f" && err "$name: cpu variant pins a card"
            ;;
        *) err "$name: unexpected docling variant '$variant'" ;;
    esac
done

[ "$fail" = 0 ] && echo "Docling variants passed." || exit 1
