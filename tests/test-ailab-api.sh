#!/usr/bin/env bash
# ailab-api (mac-quadlet-widget P0): quadlet shape, registry entry, and the
# stdlib API server compiling. Network=host units must not PublishPort
# (test-registry-consistency's rule); the unit is boot tier so the Mac widget
# never gaps.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "  FAIL: $*"; exit 1; }

q="$ROOT/quadlets/ailab-api.container"
[ -f "$q" ] || fail "missing quadlets/ailab-api.container"
grep -qx 'Network=host' "$q" || fail "ailab-api must use Network=host"
grep -q '^PublishPort=' "$q" && fail "Network=host unit must not PublishPort"
grep -qx 'SuccessExitStatus=143' "$q" || fail "lacks SuccessExitStatus=143"
grep -q '^\[Install\]' "$q" || fail "control plane must carry [Install] (boot tier)"
grep -q '^[^#]*%t/bus' "$q" || fail "must mount the systemd user session bus socket"
grep -q 'EnvironmentFile=%h/.config/containers/config/ailab-api/service.env' "$q" \
    || fail "token must come from the config env file, not the unit"

python3 - "$ROOT" <<'EOF' || exit 1
import json, sys
root = sys.argv[1]
s = next((x for x in json.load(open(f"{root}/services.json"))["services"]
          if x["name"] == "ailab-api"), None)
if s is None:
    print("  FAIL: ailab-api missing from services.json"); sys.exit(1)
ok = (s["unit"] == "ailab-api.service" and s["container"] == "systemd-ailab-api"
      and s["host_port"] == 3119 and s["bind"] == "127.0.0.1"
      and s["health"] == "/healthz" and s["image"] == "localhost/ailab-api:latest"
      and s["boot"] is True and s["tier"] == "control")
if not ok:
    print(f"  FAIL: registry entry shape wrong: {s}"); sys.exit(1)
EOF

python3 -m py_compile "$ROOT/containers/ailab-api/api.py"

env_ex="$ROOT/config/ailab-api/service.env.example"
[ -f "$env_ex" ] || fail "missing config/ailab-api/service.env.example"
grep -qx '^AILAB_API_TOKEN=change-me-to-a-random-hex-string$' "$env_ex" \
    || fail "env example must carry the generator placeholder"
grep -qx '^VSCODE_PR_SIGNING_SECRET=change-me-to-a-second-random-hex-string$' "$env_ex" \
    || fail "env example must carry the vscode-pr signing placeholder"

# vscode-pr review-button backend (docs/vscode-pr-review-plan.md)
python3 -m py_compile "$ROOT/containers/ailab-api/vscode_pr_api.py"
grep -q 'COPY vscode_pr_api.py /app/' "$ROOT/containers/ailab-api/Containerfile" \
    || fail "vscode_pr_api.py must ship in the image"
grep -q 'fly-8.3.3-linux-amd64.tgz' "$ROOT/containers/ailab-api/Containerfile" \
    || fail "fly must be pinned to the server version in the image"
for tmpl in vscode-pr-up.yml.tmpl vscode-pr-down.yml.tmpl; do
    [ -f "$ROOT/pipelines/$tmpl" ] || fail "missing pipelines/$tmpl"
done
grep -q 'register-ssh-key' "$ROOT/pipelines/vscode-pr-up.yml.tmpl" \
    || fail "creation pipeline must carry the SSH key generation+registration step"
grep -q 'teardown' "$ROOT/pipelines/vscode-pr-down.yml.tmpl" \
    || fail "destruction pipeline must carry the teardown step"
grep -q '^Volume=%h/.workspaces/vscode-pr:/home/px/.workspaces/vscode-pr$' \
    "$ROOT/quadlets/ailab-api.container" \
    || fail "ailab-api must mount the vscode-pr state dir (same path)"
[ -f "$ROOT/scripts/vscode-pr-env.sh" ] || fail "missing host env lifecycle script"
[ -f "$ROOT/scripts/vscode-pr-doors.sh" ] || fail "missing tailscale door pool script"
[ -f "$ROOT/scripts/ragflow-fix-admin-password.sh" ] \
    || fail "missing ragflow admin password repair script"

echo "ailab-api checks passed."
