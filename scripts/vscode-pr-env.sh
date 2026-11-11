#!/usr/bin/env bash
# vscode-pr-env.sh — host-side lifecycle of per-PR VS Code review boxes.
#
# Called (over SSH, as px, by the vscode-pr Concourse pipelines) and by hand:
#   scripts/vscode-pr-env.sh create  <slug> <owner> <repo> <pr> <port> <git-name> <git-email>   # reads the PR-scoped private SSH key from STDIN
#   scripts/vscode-pr-env.sh destroy <slug>
#   scripts/vscode-pr-env.sh status  [<slug>]
#
# One box = one transient rootless Podman container `vscode-pr-<slug>`
# (codercom/code-server, digest-pinned below) + a state dir
# ~/.workspaces/vscode-pr/<slug>/ holding: ssh/id_ed25519 (the deploy key the
# create pipeline registered in Forgejo), token (code-server connection token,
# 0600), ws/ (the PR checkout; the container's editor folder).
#
# The box reaches Forge's git SSH at ssh://git@systemd-forge:22 with that key
# (repo deploy key, read-only, titled vscode-pr-<slug>; the destroy pipeline
# deletes it via the Forgejo API). Loopback PublishPort from a fixed pool; the
# tailnet reaches it through the pre-created TLS doors
# (scripts/vscode-pr-doors.sh: https 8450.. -> 127.0.0.1:3130..).
#
# Trust posture: containers run rootless (keep-id), no host socket, no GPU,
# ai.network only. The connection token is never printed by this script —
# readers with host access cat the file; the PR comment links the signed
# ailab-api access page instead (never the token itself).
set -euo pipefail

IMAGE="docker.io/codercom/code-server@sha256:aaad9c5f5ecb70713188e8466060f186b08bd328cd3e1bcffc4a2a2dca33c14b"  # 4.145.2 linux/amd64 (resolved from the registry index 2026-11-11)
BASE="$HOME/.workspaces/vscode-pr"
POOL="3130 3131 3132 3133 3134 3135"

die() { printf 'vscode-pr-env: %s\n' "$*" >&2; exit 1; }

valid_slug() { printf '%s' "$1" | grep -Eq '^[a-z0-9][a-z0-9-]{0,47}$'; }
valid_repo() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._-]{1,64}$'; }

envdir() { printf '%s/%s' "$BASE" "$1"; }

container_name() { printf 'vscode-pr-%s' "$1"; }

pick_port() {  # first pool port not claimed by an existing env
    for p in $POOL; do
        [ -e "$(envdir "port-$p")" ] && continue
        podman ps -a --filter "publish=$p" --format '{{.Names}}' | grep -q . && continue
        printf '%s' "$p"; return 0
    done
    return 1
}

cmd_create() {
    local slug="$1" owner="$2" repo="$3" pr="$4" port="$5" gname="$6" gemail="$7"
    valid_slug "$slug" || die "bad slug"
    valid_repo "$owner" && valid_repo "$repo" || die "bad owner/repo"
    case "$pr" in (*[!0-9]*|'') die "bad pr number" ;; esac
    printf '%s' "$port" | grep -Eq '^313[0-5]$' || die "port must be from the pool: $POOL"
    local d; d="$(envdir "$slug")"
    # self-healing retry: a failed earlier attempt's container/state is
    # cleared first (re-running -up/create after a partial failure is safe)
    if [ -e "$d" ]; then
        printf 're-creating over existing env %s\n' "$slug"
        cmd_destroy "$slug"
    fi
    mkdir -p "$d/ssh" "$d/ws"
    chmod 700 "$d"
    # private key arrives on STDIN (never argv, never a log)
    umask 077
    cat > "$d/ssh/id_ed25519"
    [ -s "$d/ssh/id_ed25519" ] || die "empty private key on stdin"
    ssh-keygen -y -f "$d/ssh/id_ed25519" > "$d/ssh/id_ed25519.pub" 2>/dev/null \
        || die "private key unreadable (not a valid ed25519 PEM?)"
    openssl rand -hex 16 > "$d/token"
    # identity + access metadata for the pipelines and ailab-api access page
    printf 'slug=%s\nowner=%s\nrepo=%s\npr=%s\nport=%s\ngit_name=%s\ngit_email=%s\ncreated=%s\n' \
        "$slug" "$owner" "$repo" "$pr" "$port" "$gname" "$gemail" "$(date -u +%FT%TZ)" > "$d/state"
    touch "$BASE/port-$port"

    podman pull -q "$IMAGE" >/dev/null
    podman run -d --init \
        --name "vscode-pr-$slug" \
        --userns=keep-id \
        --network systemd-ai \
        -p "127.0.0.1:$port:8080" \
        -v "$d:/home/coder/pr-env:Z" \
        -e PR_OWNER="$owner" -e PR_REPO="$repo" -e PR_NUM="$pr" \
        -e GIT_REVIEWER_NAME="$gname" -e GIT_REVIEWER_EMAIL="$gemail" \
        --entrypoint /bin/bash \
        "$IMAGE" -c '
set -euo pipefail
mkdir -p ~/.ssh && chmod 700 ~/.ssh
install -m 600 /home/coder/pr-env/ssh/id_ed25519 ~/.ssh/id_ed25519
git config --global user.name  "$GIT_REVIEWER_NAME"
git config --global user.email "$GIT_REVIEWER_EMAIL"
git config --global init.defaultBranch main
export GIT_SSH_COMMAND="ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
git clone "ssh://git@systemd-forge/$PR_OWNER/$PR_REPO.git" "/home/coder/pr-env/ws/$PR_REPO"
cd "/home/coder/pr-env/ws/$PR_REPO"
git fetch origin "+refs/pull/$PR_NUM/head:refs/heads/pr-$PR_NUM"
git checkout "pr-$PR_NUM"
touch /home/coder/pr-env/ready
# 4.145.2 (verified live from the pinned image): --auth takes
# [password|none]; --password is REJECTED on argv ("can only be set in the
# config file or passed in via $PASSWORD") and there is no --password-file.
# The entry reads the mounted token file into the PASSWORD env at exec time.
exec env PASSWORD="*** /home/coder/pr-env/token)" code-server \
     --auth password --bind-addr 0.0.0.0:8080 "/home/coder/pr-env/ws/$PR_REPO"
' >/dev/null
    printf 'created vscode-pr-%s port=%s\n' "$slug" "$port"
}

cmd_destroy() {
    local slug="$1"; valid_slug "$slug" || die "bad slug"
    local d; d="$(envdir "$slug")"
    local port=""
    [ -f "$d/state" ] && port=$(sed -n 's/^port=//p' "$d/state")
    podman rm -f "vscode-pr-$slug" >/dev/null 2>&1 || true
    if podman container exists "vscode-pr-$slug" 2>/dev/null; then die "container still present"; fi
    rm -rf "$d"
    [ -n "$port" ] && rm -f "$BASE/port-$port"
    printf 'destroyed vscode-pr-%s\n' "$slug"
}

cmd_status() {
    local slug="${1:-}"
    if [ -n "$slug" ]; then
        valid_slug "$slug" || die "bad slug"
        d="$(envdir "$slug")"
        [ -f "$d/state" ] || die "no env $slug"
        running=$(podman ps --filter "name=vscode-pr-$slug" --format '{{.State}}')
        printf 'slug=%s port=%s container=%s ready=%s\n' "$slug" \
            "$(sed -n 's/^port=//p' "$d/state")" "${running:-absent}" \
            "$([ -e "$d/ready" ] && echo yes || echo no)"
    else
        for f in "$BASE"/*/state; do
            [ -e "$f" ] || continue
            d=${f%/state}; s=${d##*/}
            running=$(podman ps --filter "name=vscode-pr-$s" --format '{{.State}}')
            printf 'slug=%s port=%s container=%s\n' "$s" "$(sed -n 's/^port=//p' "$f")" "${running:-absent}"
        done
    fi
}

case "${1:-}" in
    create)  shift; [ $# -eq 7 ] || die "create needs slug owner repo pr port git-name git-email (key on stdin)"; cmd_create "$@" ;;
    destroy) shift; [ $# -eq 1 ] || die "destroy needs slug"; cmd_destroy "$@" ;;
    status)  shift; cmd_status "${1:-}" ;;
    *) die "usage: vscode-pr-env.sh create|destroy|status" ;;
esac
