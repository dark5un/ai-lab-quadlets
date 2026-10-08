#!/usr/bin/env bash
# Drift alarm: every non-opt-in service in services.json must match the
# quadlet's PublishPort (bind:host_port:container_port) and Image.
# Checks the deployed quadlet dir when present, else the repo quadlets/.
# A quadlets/<name>.container.in template (GPU UUID placeholders) counts as
# the quadlet; scripts/render-units.sh renders it at install time.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REG="$ROOT/services.json"
DEPLOYED="${HOME}/.config/containers/systemd"

fail=0
check() { # name file
    local name="$1" file="$2"
    local expect image actual
    expect=$(python3 - "$REG" "$name" <<'EOF'
import json, sys
reg = json.load(open(sys.argv[1]))
for s in reg["services"]:
    if s["name"] == sys.argv[2]:
        print(f"{s['bind']}:{s['host_port']}:{s['container_port']}")
        print(s["image"])
        sys.exit(0)
sys.exit(1)
EOF
)
    local want_port want_image
    want_port=$(sed -n 1p <<<"$expect")
    want_image=$(sed -n 2p <<<"$expect")

    actual=$( (grep -E '^PublishPort=' "$file" | head -1 || true) | sed 's/^PublishPort=//; s|/tcp$||')
    # Network=host services (deepseek-harness) publish no port: the app binds
    # itself. Assert the quadlet really uses host networking instead.
    if grep -qE '^Network=host' "$file"; then
        if [ -n "$actual" ]; then
            echo "  DRIFT: $name has Network=host but also PublishPort '$actual'"
            fail=1
        fi
    elif [ "$actual" != "$want_port" ]; then
        echo "  DRIFT: $name PublishPort '$actual' != registry '$want_port' ($file)"
        fail=1
    fi
    image=$( (grep -E '^Image=' "$file" | head -1 || true) | sed 's/^Image=//')
    if [ "$image" != "$want_image" ]; then
        echo "  DRIFT: $name image '$image' != registry '$want_image' ($file)"
        fail=1
    fi
}

for svc in $(python3 -c "import json,sys; [print(s['name']) for s in json.load(open('$REG'))['services']]"); do
    file=""
    [ -f "$DEPLOYED/$svc.container" ] && file="$DEPLOYED/$svc.container"
    [ -f "$ROOT/quadlets/$svc.container" ] && file="$ROOT/quadlets/$svc.container"
    [ -f "$ROOT/quadlets/$svc.container.in" ] && file="$ROOT/quadlets/$svc.container.in"
    if [ -z "$file" ]; then
        echo "  MISSING: no quadlet found for $svc"
        fail=1
        continue
    fi
    check "$svc" "$file"
done

if [ "$fail" = 0 ]; then
    echo "Registry consistency passed: all services match services.json."
else
    echo "Registry drift detected (see above)."
    exit 1
fi
