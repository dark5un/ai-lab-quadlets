#!/usr/bin/env bash
# pipeline-bootstrap.sh — one-time (idempotent) activation wiring for the
# agentic-pipeline plan (Concourse + Garage + Forgejo + concourse-mcp).
#
#   scripts/pipeline-bootstrap.sh
#
# Prereq: the pipeline units are up (forge, forge-postgres, s3,
# concourse-postgres, concourse-web, concourse-worker, concourse-mcp).
# Reads every secret from the $CONF env files itself and NEVER prints a
# value (agent-safe: no secret ever appears in an argv/terminal command).
#
# Steps:
#   1. install the matching fly CLI into ~/.local/bin (fetched from the
#      running web node: GET /api/v1/cli?arch=amd64&platform=linux)
#   2. wait for HTTP readiness of forge / concourse-web / s3 / mcp
#   3. Garage: layout apply, bucket ci-artifacts, key 'pipeline'
#      (key id/secret captured -> config/s3/service.env), seed the
#      versioned_file object so the s3 resource check starts green
#   4. Forgejo: admin user (from service.env), repo pipeline-lab seeded,
#      scoped API token -> vars
#   5. Concourse: fly login (pipeline user), set-team agent (low-priv),
#      write config/concourse/pipeline-vars.yml (0600), set-pipeline agentic
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
CONF="${AI_LAB_CONFIG_DIR:-${HOME}/.config/containers/config}"
NET=systemd-ai
VARS="$CONF/concourse/pipeline-vars.yml"
say() { printf '  %s\n' "$*"; }
die() { printf '  ! %s\n' "$*" >&2; exit 1; }
envval() { sed -n "s/^$2=//p" "$1" | tail -1; }
wait_http() {  # wait_http <url> <desc> [tries]
    local n=${3:-60}
    for _ in $(seq "$n"); do
        curl -fsS -o /dev/null --max-time 3 "$1" 2>/dev/null && { say "ready: $2"; return 0; }
        sleep 2
    done
    die "$2 not ready at $1"
}
# readiness that accepts any HTTP response (root paths answer 404/403 but prove liveness)
wait_any_http() {  # wait_any_http <url> <desc> [tries]
    local n=${3:-40}
    for _ in $(seq "$n"); do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$1" 2>/dev/null || echo 000)
        [ "$code" != 000 ] && { say "up: $2 -> $code"; return 0; }
        sleep 2
    done
    die "no HTTP answer from $1"
}

# ─── 1. fly CLI (version must match the server) ─────────────────────────────
FLY="$HOME/.local/bin/fly"
if [ ! -x "$FLY" ]; then
    say "fetching fly client from the web node"
    curl -fsS -o "$FLY" "http://127.0.0.1:3122/api/v1/cli?arch=amd64&platform=linux"
    chmod +x "$FLY"
fi
"$FLY" --version | head -1

# ─── 1b. Forgejo volume ownership (one-time; idempotent) ───────────────────
# The image entrypoint only mkdir's /data/*; the s6-supervised server runs as
# USER_UID:USER_GID (1000:1000 in-container). Pre-own the named volumes so it
# can write (run in-container as ns-root; never from the host).
podman volume create forge-data forge-ssh >/dev/null 2>&1 || true
podman run --rm -v forge-data:/data -v forge-ssh:/data/ssh \
    codeberg.org/forgejo/forgejo:17.0.1 \
    sh -c 'mkdir -p /data/gitea/conf /data/gitea/log /data/git /data/ssh && chown -R 1000:1000 /data' \
    && say "forge volumes owned 1000:1000"

# ─── 2. readiness ────────────────────────────────────────────────────────────
wait_any_http http://127.0.0.1:3121 "garage s3"
wait_http    "http://127.0.0.1:3120/api/v1/version" forge
wait_http    "http://127.0.0.1:3122/api/v1/info" concourse-web
wait_http    "http://127.0.0.1:3123/healthz" concourse-mcp

# ─── 3. Garage ───────────────────────────────────────────────────────────────
gexec() { podman exec systemd-s3 /garage "$@"; }
gexec layout show 2>/dev/null | grep -q 'CURRENT CLUSTER LAYOUT' || \
    gexec layout apply --version 1 2>/dev/null || true
# v2.5.0 status sections: HEALTHY NODES (verified live)
gexec status 2>/dev/null | grep -q 'HEALTHY NODES' || die "garage node not healthy"
gexec bucket list 2>/dev/null | grep -q 'ci-artifacts' || gexec bucket create ci-artifacts 2>&1 | grep -vE 'INFO garage' >/dev/null
if [ ! -f "$CONF/s3/service.env" ]; then
    say "creating garage access key 'pipeline'"
    tmpk=$(mktemp)
    gexec key create pipeline > "$tmpk" 2>/dev/null
    # v2.5.0 text output: "Key ID:   GK..." / "Secret key: ..." label lines
    ak=$(sed -n 's/^Key ID:[[:space:]]*//p' "$tmpk" | head -1)
    sk=$(sed -n 's/^Secret key:[[:space:]]*//p' "$tmpk" | head -1)
    rm -f "$tmpk"
    { echo "GARAGE_KEY_ID=$ak"; echo "GARAGE_SECRET=$sk"; } > "$CONF/s3/service.env"
    chmod 600 "$CONF/s3/service.env"
    gexec bucket allow --read --write --owner ci-artifacts --key pipeline
    say "wrote config/s3/service.env (600) + granted bucket"
else
    gexec bucket allow --read --write --owner ci-artifacts --key pipeline >/dev/null 2>&1 || true
fi
AK=$(envval "$CONF/s3/service.env" GARAGE_KEY_ID)
SK=$(envval "$CONF/s3/service.env" GARAGE_SECRET)
# seed the versioned_file object (s3-resource check needs it green on first
# run) with the stdlib SigV4 helper in a one-shot python container on the
# stack network (MinIO's own mc image is off Docker Hub since the archive).
s3probe() {  # s3probe <op:ls|seed> <bucket> <key> [local-file]
    local op="$1" bucket="$2" key="$3" file="${4:-}" mount=()
    [ -n "$file" ] && mount=(-v "$file:/tmp/f:ro")
    podman run --rm --network "$NET" \
        -e S3_ENDPOINT=http://systemd-s3:3900 -e S3_REGION=garage \
        -e S3_AK="$AK" -e S3_SK="$SK" \
        -v "$ROOT/scripts/s3-probe.py:/app/s3-probe.py:ro" \
        ${mount[@]+"${mount[@]}"} \
        --entrypoint python docker.io/library/python:3.14-slim \
        /app/s3-probe.py "$op" "$bucket" "$key" ${file:+/tmp/f}
}
if ! s3probe ls ci-artifacts build/latest.tar.gz; then
    say "seeding build/latest.tar.gz"
    printf 'seed artifact (agentic-pipeline bootstrap)\n' > /tmp/pipeline-seed.tar
    s3probe seed ci-artifacts build/latest.tar.gz /tmp/pipeline-seed.tar
    rm -f /tmp/pipeline-seed.tar
fi

# ─── 4. Forgejo admin + repo + token ────────────────────────────────────────
FSVC="$CONF/forge/service.env"
[ -f "$FSVC" ] || die "missing $FSVC (generate-secrets.sh)"
ADMIN=$(envval "$FSVC" FORGEJO_ADMIN_USER)
APW=$(envval "$FSVC" FORGEJO_ADMIN_PASSWORD)
# CLI needs the forgejo home of the running instance; probe once.
# exec as the git user: Forgejo's CLI refuses root ("not supposed to be run
# as root", verified live 2026-11-10; the container's entrypoint pid is root
# for s6 supervision but app/CLI processes must be USER_UID)
if ! podman exec --user git systemd-forge forgejo admin user list 2>/dev/null | grep -q "$ADMIN"; then
    say "creating forgejo admin user '$ADMIN'"
    podman exec --user git systemd-forge forgejo admin user create \
        --admin --username "$ADMIN" --password "$APW" \
        --email "$ADMIN@ai-lab.invalid" || die "forgejo admin user create failed"
fi
# scoped API token (git basic-auth password for the git resource)
if [ ! -s "$CONF/forge/token" ]; then  # -s: an empty leftover from a failed run must regenerate
    say "creating forgejo API token 'concourse' (write:repository)"
    podman exec --user git systemd-forge forgejo admin user generate-access-token \
        --raw --username "$ADMIN" --token-name "concourse-$(date +%s)" \
        --scopes "write:repository,read:repository,write:user,read:user" > "$CONF/forge/token"  # write:user needed for repo creation (Forgejo 17, verified live)
    chmod 600 "$CONF/forge/token"
fi
TOK=$(cat "$CONF/forge/token")
# repo pipeline-lab + seed README commit (idempotent via the API)
if ! curl -fsS -H "Authorization: token $TOK" \
        "http://127.0.0.1:3120/api/v1/repos/$ADMIN/pipeline-lab" >/dev/null 2>&1; then
    say "creating repo pipeline/pipeline-lab"
    curl -fsS -H "Authorization: token $TOK" -H 'Content-Type: application/json' \
        -d '{"name":"pipeline-lab","auto_init":true,"default_branch":"main"}' \
        "http://127.0.0.1:3120/api/v1/user/repos" >/dev/null \
        || die "forgejo repo create failed"
fi
if ! curl -fsS -H "Authorization: token $TOK" \
        "http://127.0.0.1:3120/api/v1/repos/$ADMIN/pipeline-lab/contents/README.md" >/dev/null 2>&1; then
    say "seeding README.md"
    body=$(printf '{"content":"%s","message":"seed pipeline-lab"}' \
        "$(printf 'Agentic pipeline lab (Concourse git resource target).\n' | base64 -w0)")
    curl -fsS -X POST -H "Authorization: token $TOK" -H 'Content-Type: application/json' \
        -d "$body" \
        "http://127.0.0.1:3120/api/v1/repos/$ADMIN/pipeline-lab/contents/README.md" >/dev/null \
        || die "forgejo README seed failed"
fi

# ─── 5. Concourse teams + vars + pipeline ───────────────────────────────────
WEBPW=$(sed -n 's/^CONCOURSE_ADD_LOCAL_USER=pipeline:\([^,]*\),.*/\1/p' "$CONF/concourse/web.env")
"$FLY" -t local login -c http://127.0.0.1:3122 -n main -u pipeline -p "$WEBPW" >/dev/null
"$FLY" -t local set-team -n agent --local-user=agent --non-interactive >/dev/null  # fly 8.3.3 TUI needs the flag (verified)
# agent-team pipeline (the low-priv MCP token's trigger target; proves the
# token->team mapping in the agent-smoke task)
"$FLY" -t agent login -c http://127.0.0.1:3122 -n agent -u agent \
    -p "$(sed -n 's/^CONCOURSE_ADD_LOCAL_USER=[^,]*,agent:\(.*\)$/\1/p' "$CONF/concourse/web.env")" >/dev/null
"$FLY" -t agent set-pipeline -p agentic-agent -c "$ROOT/pipelines/agentic-agent.yml" --non-interactive 2>&1 | tail -1
say "teams: main (pipeline) + agent (low-priv, agentic-agent set)"

STRATA_KEY=$(envval "$CONF/strata/service.env" API_KEY)
[ -n "$STRATA_KEY" ] || die "strata API_KEY not found in $CONF/strata/service.env"
MCP_LOW=$(envval "$CONF/concourse/mcp.env" MCP_TOKEN_PIPELINE)
python3 - "$VARS" "$ADMIN" "$TOK" "$AK" "$SK" "$STRATA_KEY" "$MCP_LOW" <<'PY'
import os, sys
path, user, token, ak, sk, strata, mcp_low = sys.argv[1:8]
vals = {"forge-user": user, "forge-token": token, "s3-ak": ak, "s3-sk": sk,
        "strata-key": strata, "mcp-lowpriv-token": mcp_low}
with open(path, "w") as f:
    for k, v in vals.items():
        f.write(f"{k}: \"{v}\"\n")
os.chmod(path, 0o600)
print("  wrote %s (0600, 6 vars, values never printed)" % path)
PY

"$FLY" -t local set-pipeline -p agentic -n -c "$ROOT/pipelines/agentic.yml" -l "$VARS" --non-interactive 2>&1 | tail -3
"$FLY" -t local unpause-pipeline -p agentic >/dev/null 2>&1 || true
say "pipeline 'agentic' set (team main; git + s3 edges use the ((vars)) above)"

# ─── 6. vscode-pr review-button wiring (docs/vscode-pr-review-plan.md) ─────
# ailab-api grows the signed button backend that creates the per-change
# create/destroy Concourse pipelines; the pipelines' tasks SSH to THIS host
# (rootless podman lifecycle) with a dedicated keypair. All values move
# host->host between 0600 files; nothing secret is printed.
say "wiring vscode-pr backend"
TAILNET=$(tailscale status --json | python3 -c 'import sys,json;print(json.load(sys.stdin)["Self"]["DNSName"].rstrip(".").split(".",1)[1])')
TS_IP=$(tailscale ip -4)
BOXKEY="$CONF/concourse/vscode-box_ed25519"
if [ ! -f "$BOXKEY" ]; then
    say "generating vscode-box ssh keypair"
    ssh-keygen -q -t ed25519 -N '' -C "concourse-vscode-box" -f "$BOXKEY"
    chmod 600 "$BOXKEY"; chmod 644 "$BOXKEY.pub"
fi
if ! grep -qFf "$BOXKEY.pub" "$HOME/.ssh/authorized_keys" 2>/dev/null; then
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    cat "$BOXKEY.pub" >> "$HOME/.ssh/authorized_keys" && chmod 600 "$HOME/.ssh/authorized_keys"
    say "authorized the vscode-box key for $(id -un)@this host"
fi
mkdir -p "$HOME/.workspaces/vscode-pr" && chmod 700 "$HOME/.workspaces/vscode-pr"

AENV="$CONF/ailab-api/service.env"
PIPEPW=$(sed -n 's/^CONCOURSE_ADD_LOCAL_USER=pipeline:\([^,]*\),.*/\1/p' "$CONF/concourse/web.env")
python3 - "$AENV" "$TS_IP" "$TAILNET" "$PIPEPW" "$BOXKEY" "$ROOT" "$(id -un)" <<'PY'
import base64, os, pathlib, sys
aenv, ts_ip, tailnet, piptok, boxkey, root, user = sys.argv[1:8]
p = pathlib.Path(aenv)
lines = p.read_text().splitlines() if p.is_file() else []
vals = {
    "VSCODE_PR_FORGE_API": "http://127.0.0.1:3120",
    "VSCODE_PR_FORGE_TOKEN": open(
        os.path.join(os.path.dirname(aenv), "..", "forge", "token")).read().strip(),
    "VSCODE_PR_CONCOURSE_URL": "http://127.0.0.1:3122",
    "VSCODE_PR_CONCOURSE_PUBLIC": f"https://concourse.{tailnet}",
    "VSCODE_PR_CONCOURSE_USER": "pipeline",
    "VSCODE_PR_CONCOURSE_PASSWORD": piptok,
    "VSCODE_PR_BOX_SSH_B64": base64.b64encode(open(boxkey, "rb").read()).decode(),
    "VSCODE_PR_BOX_SSH_HOST": ts_ip,
    "VSCODE_PR_BOX_SSH_USER": user,
    "VSCODE_PR_ENV_SCRIPT": os.path.join(root, "scripts", "vscode-pr-env.sh"),
    "VSCODE_PR_REPO": root,
    "VSCODE_PR_STATE_ROOT": os.path.expanduser("~/.workspaces/vscode-pr"),
    "VSCODE_PR_PUBLIC_BASE": f"https://ai.{tailnet}:8448",
    "VSCODE_PR_DOOR_BASE": f"https://ai.{tailnet}",
    "VSCODE_PR_POOL": "3130 3131 3132 3133 3134 3135",
}
known = {l.split("=", 1)[0] for l in lines if "=" in l}
for k, v in vals.items():
    if k in known:
        lines = [f"{k}={v}" if l.startswith(k + "=") else l for l in lines]
    else:
        lines.append(f"{k}={v}")
p.write_text("\n".join(lines) + "\n")
os.chmod(p, 0o600)
print("  ailab-api/service.env: %d vscode-pr keys upserted" % len(vals))
PY

# pipeline-vars additions for the repo-review agent (button signing)
python3 - "$VARS" "$CONF/ailab-api/service.env" "$TAILNET" <<'PY'
import os, pathlib, sys
path, aenv, tailnet = sys.argv[1:4]
sign = None
for line in pathlib.Path(aenv).read_text().splitlines():
    if line.startswith("VSCODE_PR_SIGNING_SECRET="):
        sign = line.split("=", 1)[1]
if not sign:
    sys.exit("VSCODE_PR_SIGNING_SECRET missing from ailab-api env (run generate-secrets.sh)")
txt = pathlib.Path(path).read_text()
adds = []
if "vscode-pr-signing-secret:" not in txt:
    adds.append(f'vscode-pr-signing-secret: "{sign}"')
if "ailab-public-url:" not in txt:
    adds.append(f'ailab-public-url: "https://ai.{tailnet}:8448"')
if adds:
    with open(path, "a") as f:
        f.write("\n".join(adds) + "\n")
    os.chmod(path, 0o600)
print("  pipeline-vars.yml: appended %s" % ", ".join(a.split(":")[0] for a in adds))
PY

systemctl --user restart ailab-api.service 2>/dev/null && say "ailab-api restarted (vscode-pr env loaded)" || say "note: ailab-api not running; start it to activate"
say "bootstrap done."
