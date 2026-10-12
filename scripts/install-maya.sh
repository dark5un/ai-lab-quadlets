#!/usr/bin/env bash
# install-maya.sh — deploy the Project Maya quadlet variants (maya-5090-256,
# -512, -1024 on the 5090 alone, maya-both-256, -512, -1024 on both cards; one
# at a time, fully exclusive: any maya start stops every strata instance and
# vice versa) as user quadlets, and write the per-context maya configs into
# the maya repo checkout the units bind-mount.
#
#   ./scripts/install-maya.sh
#
# The engine image localhost/maya-runtime:latest already exists (the
# user built it with maya's own tooling; we do not rebuild it here —
# maya.py compiles build/strata inside the container on --setup).
#
# Nothing is started. Switch variants with `ai-lab maya <variant>|off`
# or the AI Lab bar widget. The two live configs today (maya-maya-s24.json,
# maya-maya-s-v2-iq2_xxs.json at 1M) keep working: the new per-context
# configs are copies with only --max-context patched (the packs are shared).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUADLET_DIR="${HOME}/.config/containers/systemd"
MAYA_REPO="${MAYA_REPO:-${HOME}/src/project-maya}"
MAYA_MODELS="${MAYA_MODELS:-${HOME}/.local/share/maya/models}"

VARIANTS="maya-5090-256 maya-5090-512 maya-5090-1024 maya-both-256 maya-both-512 maya-both-1024"
CTX_OF() {  # variant -> 256|512|1024
    case "$1" in *-256) echo 256;; *-512) echo 512;; *-1024) echo 1024;; esac
}
BASE_OF() {  # variant -> the installed base config it copies (both = S24, 5090 = S-v2)
    case "$1" in maya-both-*) echo "maya-maya-s24.json";; *) echo "maya-maya-s-v2-iq2_xxs.json";; esac
}
TOK_OF() {
    case "$1" in *-256) echo 262144;; *-512) echo 524288;; *-1024) echo 1048576;; esac
}

for cmd in podman nvidia-smi python3 systemctl; do
    command -v "$cmd" >/dev/null 2>&1 || { printf 'Required command not found: %s\n' "$cmd" >&2; exit 1; }
done

# --- preconditions -------------------------------------------------------------
[ -d "$MAYA_REPO" ] || { printf 'Maya checkout not found at %s (set MAYA_REPO).\n' "$MAYA_REPO" >&2; exit 1; }
[ -f "$MAYA_REPO/maya.py" ] || { printf '%s is not a maya checkout (no maya.py).\n' "$MAYA_REPO" >&2; exit 1; }
# the two base configs must exist (written by maya.py --setup on first install)
for b in maya-maya-s24.json maya-maya-s-v2-iq2_xxs.json; do
    [ -f "$MAYA_REPO/$b" ] || { printf 'Missing %s/%s — run maya setup for both packs first (see maya README).\n' "$MAYA_REPO" "$b" >&2; exit 1; }
done

# --- per-context configs ---------------------------------------------------------
# A copy of the base config with --max-context patched; maya.py's server_command
# reads args from the config, and set_arg replaces an existing flag's value.
python3 - "$MAYA_REPO" <<'EOF'
import json, sys
root = sys.argv[1]
TOK = {"256": 262144, "512": 524288, "1024": 1048576}
for variant, base, cfg in (
    ("maya-5090-256", "maya-maya-s-v2-iq2_xxs.json", "maya-maya-5090-256.json"),
    ("maya-5090-512", "maya-maya-s-v2-iq2_xxs.json", "maya-maya-5090-512.json"),
    ("maya-5090-1024", "maya-maya-s-v2-iq2_xxs.json", "maya-maya-5090-1024.json"),
    ("maya-both-256", "maya-maya-s24.json", "maya-maya-both-256.json"),
    ("maya-both-512", "maya-maya-s24.json", "maya-maya-both-512.json"),
    ("maya-both-1024", "maya-maya-s24.json", "maya-maya-both-1024.json"),
):
    d = json.load(open(f"{root}/{base}"))
    args = d.setdefault("args", [])
    ctx = str(TOK[variant.rsplit("-", 1)[1]])
    if "--max-context" in args:
        args[args.index("--max-context") + 1] = ctx
    else:
        args += ["--max-context", ctx]
    with open(f"{root}/{cfg}", "w") as f:
        json.dump(d, f, indent=1)
        f.write("\n")
    print(f"  {cfg}: --max-context {ctx}")
EOF

# --- units -----------------------------------------------------------------------
# render-units.sh renders quadlets/<name>.container.in (GPU UUID placeholders,
# cards matched by name, never by index); it does not daemon-reload.
"$ROOT/scripts/render-units.sh" $VARIANTS

systemctl --user daemon-reload
echo "  ✓ daemon-reload (maya variants installed; none started)"
echo "  switch with: ai-lab maya <256|512|1024>  and  ai-lab maya both|off"
