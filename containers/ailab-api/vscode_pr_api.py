#!/usr/bin/env python3
"""vscode_pr_api — PR review-button backend inside ailab-api.

A review comment posted by the repo-review agent carries a signed "button"
link (Forgejo 17.0.1 has no native review-button primitive — verified live:
zero reviewprompt strings in the /app/gitea/gitea binary). Clicking it opens
this interstitial; submitting it creates TWO Concourse pipelines for exactly
this change:

  vscode-pr-<slug>-up     the creation pipeline (unpaused, triggered):
                          generates + registers a repo-scoped READ-ONLY
                          deploy key (temporary, this-change-only), boots
                          the per-PR code-server box on the host, comments
                          the PR with access + teardown instructions.
  vscode-pr-<slug>-down   the destruction pipeline (created PAUSED):
                          removes the container and every temporary
                          credential (deploy key revoked via the Forgejo
                          API, host state dir + private key deleted), then
                          deletes both pipelines.

Security:
  * links carry verb+scope+expiry, HMAC-SHA256(VSCODE_PR_SIGNING_SECRET,
    "vpr|<verb>|<owner>/<repo>|<pr>|<exp>")[:32], compared constant-time;
  * the triggering person names themselves as a FORGE user; the identity is
    validated live against the Forgejo API and the box's git user.name /
    user.email are taken from that forge account's profile (the requirement:
    the git reviewer identity relates to the forge user that triggered the
    creation);
  * the connection token is NEVER put in a PR comment — the comment links a
    second signed access page which renders it from the host state dir;
  * all Concourse mutations run through fly (baked in the image), argv-only,
    with timeouts; nothing is shell-interpolated.

Env config (ailab-api/service.env):
  VSCODE_PR_SIGNING_SECRET, VSCODE_PR_FORGE_API, VSCODE_PR_FORGE_TOKEN,
  VSCODE_PR_CONCOURSE_URL, VSCODE_PR_CONCOURSE_USER, VSCODE_PR_CONCOURSE_PASSWORD,
  VSCODE_PR_BOX_SSH_B64, VSCODE_PR_BOX_SSH_HOST, VSCODE_PR_BOX_SSH_USER,
  VSCODE_PR_ENV_SCRIPT, VSCODE_PR_REPO, VSCODE_PR_PUBLIC_BASE,
  VSCODE_PR_DOOR_BASE, VSCODE_PR_POOL="3130 3131 ..."
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import html
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

CFG = {k: os.environ.get(k, "") for k in (
    "VSCODE_PR_SIGNING_SECRET", "VSCODE_PR_FORGE_API", "VSCODE_PR_FORGE_TOKEN",
    "VSCODE_PR_CONCOURSE_URL", "VSCODE_PR_CONCOURSE_USER", "VSCODE_PR_CONCOURSE_PASSWORD",
    "VSCODE_PR_BOX_SSH_B64", "VSCODE_PR_BOX_SSH_HOST", "VSCODE_PR_BOX_SSH_USER",
    "VSCODE_PR_ENV_SCRIPT", "VSCODE_PR_REPO", "VSCODE_PR_PUBLIC_BASE",
    "VSCODE_PR_DOOR_BASE", "VSCODE_PR_POOL", "VSCODE_PR_CONCOURSE_PUBLIC")}

# same-path bind from the quadlet; podman 6 rootless keep-id default means
# container uid 0 == host px (verified live: IDMappings null + session-bus auth)
STATE_ROOT = os.environ.get("VSCODE_PR_STATE_ROOT", "/home/px/.workspaces/vscode-pr")
FLY = "fly"                      # baked into the image
FLY_TARGET = "ailab"
FLY_HOME = "/tmp/ailab-api-fly"
BUTTON_TTL = 30 * 24 * 3600      # button link validity
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
VALID = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")


def configured() -> str | None:
    missing = [k for k, v in CFG.items() if not v and k != "VSCODE_PR_BOX_SSH_B64"]
    if missing:
        return "not configured (missing " + ",".join(missing) + ")"
    return None


def sign(verb: str, scope: str, pr: str, exp: int) -> str:
    msg = f"vpr|{verb}|{scope}|{pr}|{exp}".encode()
    return hmac.new(CFG["VSCODE_PR_SIGNING_SECRET"].encode(), msg, hashlib.sha256).hexdigest()[:32]


def check_sig(verb, scope, pr, exp_s, sig_s) -> str | None:
    try:
        exp = int(exp_s)
    except (TypeError, ValueError):
        return "bad expiry"
    if exp < time.time():
        return "link expired — re-run the review pipeline to get a fresh button"
    want = sign(verb, scope, pr, exp)
    if not hmac.compare_digest(want, str(sig_s or "")):
        return "bad signature"
    return None


def slug_for(owner, repo, pr) -> str:
    s = f"{owner}-{repo}-{pr}".lower()
    s = re.sub(r"[^a-z0-9-]", "-", s)
    return s[:48]


# ── Forgejo lookups ─────────────────────────────────────────────────────────
def forge_get(path: str, timeout: int = 20):
    req = urllib.request.Request(CFG["VSCODE_PR_FORGE_API"].rstrip("/") + path,
                                 headers={"Authorization": "***" + CFG["VSCODE_PR_FORGE_TOKEN"]})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        return e.code, None
    except Exception:
        return 0, None


def forge_user(name: str):
    st, d = forge_get(f"/api/v1/users/{urllib.parse.quote(name)}")
    if st == 200 and isinstance(d, dict) and d.get("username"):
        return d
    return None


def pr_title(owner, repo, pr):
    st, d = forge_get(f"/api/v1/repos/{owner}/{repo}/pulls/{pr}")
    if st == 200 and isinstance(d, dict):
        return d.get("title", ""), (d.get("user") or {}).get("username", "")
    return "", ""


# ── host state ──────────────────────────────────────────────────────────────
def env_state(slug: str):
    p = os.path.join(STATE_ROOT, slug, "state")
    if not os.path.isfile(p):
        return None
    out = {}
    for line in open(p):
        if "=" in line:
            k, _, v = line.strip().partition("=")
            out[k] = v
    return out


def free_port() -> str | None:
    taken = set()
    try:
        for e in os.scandir(STATE_ROOT):
            if e.name.startswith("port-"):
                taken.add(e.name[5:])
    except FileNotFoundError:
        pass
    for p in CFG["VSCODE_PR_POOL"].split():
        if p not in taken:
            return p
    return None


# ── fly / Concourse lifecycle ───────────────────────────────────────────────
def fly(args: list[str], timeout: int = 120) -> tuple[int, str]:
    env = dict(os.environ, HOME=FLY_HOME)
    os.makedirs(FLY_HOME, exist_ok=True)
    p = subprocess.run([FLY, "-t", FLY_TARGET, *args], capture_output=True,
                       text=True, timeout=timeout, env=env)
    return p.returncode, (p.stdout + "\n" + p.stderr).strip()


def fly_login() -> bool:
    rc, _ = fly(["login", "-c", CFG["VSCODE_PR_CONCOURSE_URL"],
                 "-u", CFG["VSCODE_PR_CONCOURSE_USER"],
                 "-p", CFG["VSCODE_PR_CONCOURSE_PASSWORD"], "--team-name", "main"])
    return rc == 0


def render(template_path: str, subs: dict[str, str]) -> str:
    """Substitute {{PLACEHOLDERS}} with YAML-scalar-safe values: every value
    is emitted as a JSON double-quoted scalar (a valid YAML one), so names
    with spaces, URLs with :// and tokens with any printable char are safe.
    Control characters / overlong values are rejected outright."""
    txt = open(os.path.join(CFG["VSCODE_PR_REPO"], "pipelines", template_path)).read()
    for k, v in subs.items():
        v = str(v)
        if re.search(r"[\x00-\x1f\x7f\u2028\u2029]", v) or len(v) > 4096:
            raise RuntimeError(f"refusing to bake {k}: control chars or overlong")
        txt = txt.replace("{{" + k + "}}", json.dumps(v))
    # any leftover placeholder is a config error: refuse to ship a broken config
    left = set(re.findall(r"{{([A-Z_]+)}}", txt))
    if left:
        raise RuntimeError(f"template {template_path}: unsubstituted {sorted(left)}")
    return txt


def launch(owner, repo, pr, user) -> tuple[bool, str, dict]:
    err = configured()
    if err:
        return False, err, {}
    if not (NAME_RE.match(owner) and NAME_RE.match(repo) and pr.isdigit()):
        return False, "bad owner/repo/pr", {}
    prof = forge_user(user)
    if not prof:
        return False, f"forge user '{user}' not found on the instance — the git identity must be a real forge account", {}
    slug = slug_for(owner, repo, pr)
    up, down = f"vscode-pr-{slug}-up", f"vscode-pr-{slug}-down"
    st = env_state(slug)
    if st and st.get("slug") == slug:
        return False, f"environment for this PR already exists on port {st.get('port')} — use the access page or destroy first", {}
    port = free_port()
    if not port:
        return False, "VS Code box pool exhausted — destroy an existing environment first", {}
    door = CFG["VSCODE_PR_DOOR_BASE"].rstrip("/") + f":{8450 + (int(port) - 3130)}"
    exp = int(time.time()) + 7 * 24 * 3600
    access_sig = sign("access", f"{owner}/{repo}", pr, exp)
    access_url = (f"{CFG['VSCODE_PR_PUBLIC_BASE'].rstrip('/')}/vscode-pr/{owner}/{repo}/{pr}"
                  f"/access?exp={exp}&sig={access_sig}")
    git_name = prof.get("full_name") or prof["username"]
    git_email = prof.get("email") or f"{prof['username']}@ai-lab.invalid"

    subs = {
        "SLUG": slug, "OWNER": owner, "REPO": repo, "PR": pr,
        "PORT": port, "DOOR_URL": door, "ACCESS_URL": access_url,
        "GIT_NAME": git_name, "GIT_EMAIL": git_email,
        "FORGE_URL": "http://systemd-forge:3000",
        "TOOLING_URI": "http://systemd-forge:3000/pipeline/pipeline-lab.git",
        "FORGE_USER": "pipeline",
        "FORGE_TOKEN": CFG["VSCODE_PR_FORGE_TOKEN"],
        "BOX_SSH_HOST": CFG["VSCODE_PR_BOX_SSH_HOST"],
        "BOX_SSH_USER": CFG["VSCODE_PR_BOX_SSH_USER"],
        "BOX_SSH_KEY_B64": CFG["VSCODE_PR_BOX_SSH_B64"],
        "ENV_SCRIPT": CFG["VSCODE_PR_ENV_SCRIPT"],
        "CONCOURSE_URL": CFG["VSCODE_PR_CONCOURSE_URL"],
        "CONCOURSE_PUBLIC_URL": (CFG.get("VSCODE_PR_CONCOURSE_PUBLIC")
                                 or CFG["VSCODE_PR_CONCOURSE_URL"]),
        "CONCOURSE_USER": CFG["VSCODE_PR_CONCOURSE_USER"],
        "CONCOURSE_PASSWORD": CFG["VSCODE_PR_CONCOURSE_PASSWORD"],
    }
    if not fly_login():
        return False, "could not log in to Concourse (fly login failed)", {}
    for name, tmpl, pause in ((up, "vscode-pr-up.yml.tmpl", False), (down, "vscode-pr-down.yml.tmpl", True)):
        cfgf = os.path.join(FLY_HOME, name + ".yml")
        open(cfgf, "w").write(render(tmpl, subs))
        rc, out = fly(["set-pipeline", "-p", name, "-c", cfgf, "--non-interactive"], 180)
        if rc != 0:
            return False, f"set-pipeline {name}: {out[-300:]}", {}
        rc, out = fly(["expose-pipeline", "-p", name], 60)
        if rc != 0:
            return False, f"expose {name}: {out[-200:]}", {}
        rc, out = fly([("pause-pipeline" if pause else "unpause-pipeline"), "-p", name], 60)
        if rc != 0:
            return False, f"pause/unpause {name}: {out[-200:]}", {}
    rc, out = fly(["trigger-job", "-j", f"{up}/create"], 60)
    if rc != 0:
        return False, f"trigger {up}/create: {out[-200:]}", {}
    info = {"slug": slug, "up": up, "down": down, "port": port, "door": door,
            "git_name": git_name, "git_email": git_email}
    sys.stderr.write(f"audit vscode-pr launch {slug} as {prof['username']} ({git_name} <{git_email}>) port={port}\n")
    return True, "", info
