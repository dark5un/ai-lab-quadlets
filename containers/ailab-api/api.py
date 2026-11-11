#!/usr/bin/env python3
"""ailab-api — tailnet-only HTTP control plane for the ai-lab-quadlets stack.

Backend for the macOS menu-bar widget (mac-quadlet-widget plan, P0). It is a
thin authenticated facade over scripts/ai-lab, so every mutation runs through
scripts/gpu-arbiter.py exactly like the CLI and the on-machine Plasma widget:
the GPU card rules can never be bypassed from the network side.

Security posture (owner directive 2026-11-10: all functionality accessible
from the tailnet):
  * binds 127.0.0.1 only; the sole exposure is the `tailscale serve` TLS door
    (tailnet-only, never LAN);
  * static bearer token (AILAB_API_TOKEN), compared in constant time;
  * service names allowlisted from services.json (names + groups); switch
    values validated against per-target regexes; argv-only subprocesses —
    no shell, no interpolation;
  * mutations serialized under a process-wide lock (the arbiter plans against
    live state; two concurrent mutations would race) and rate-gated;
  * one audit line per mutation to stderr (journal).
"""
import hmac
import json
import os
import re
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import vscode_pr_api

VERSION = "1.0"
REPO = os.environ.get("AI_LAB_REPO", "/home/px/workspace/github.com/dark5un/ai-lab-quadlets")
AILAB = os.path.join(REPO, "scripts", "ai-lab")
REGISTRY = os.path.join(REPO, "services.json")
TOKEN = os.environ.get("AILAB_API_TOKEN", "")
PORT = int(os.environ.get("AILAB_API_PORT", "3119"))
BIND = os.environ.get("AILAB_API_BIND", "127.0.0.1")

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
ACTIONS = ("start", "stop", "toggle", "restart")
PLAN_ACTIONS = ("start", "stop", "toggle")
CTX = r"(128k|256k|524k|1m)"
STRATA_VARIANT = r"(off|both|5090|4070ti|5090-524k|5090-1m|4070ti-524k|4070ti-1m)"
# Values accepted by POST /api/v1/switch/<target> (mirrors `ai-lab` usage).
SWITCH_RE = {
    "strata": re.compile(rf"^({STRATA_VARIANT}|duo( {STRATA_VARIANT})?( {CTX})?)$"),
    "coder": re.compile(rf"^(off|{CTX})$"),
    "docling": re.compile(r"^(cpu|4070ti|off)$"),
    "maya": re.compile(r"^(off|256|512|1024|(5090|both)( (256|512|1024))?)$"),
    "dictation": re.compile(r"^(gpu|cpu)$"),
}

LOCK = threading.Lock()        # serializes mutations + arbiter dry-runs
READ_TIMEOUT = 15              # status/info/plan probes
MUTATE_TIMEOUT = 300           # unit start incl. image checks
MIN_MUTATE_GAP = 1.0           # s between mutations (debounce)
_last_mutate = 0.0


def registry_targets():
    """Service names + group names — the only accepted <name> values."""
    try:
        with open(REGISTRY) as f:
            reg = json.load(f)
    except (OSError, ValueError) as e:
        raise RuntimeError(f"registry unreadable: {e}") from e
    targets = set()
    for s in reg["services"]:
        targets.add(s["name"])
        if s.get("group"):
            targets.add(s["group"])
    return targets


def ai_lab(args, timeout):
    """Run the stack CLI with an argv list (never a shell string)."""
    try:
        p = subprocess.run([AILAB, *map(str, args)],
                           capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except subprocess.TimeoutExpired:
        return 124, "", f"ai-lab {' '.join(map(str, args))}: timeout after {timeout}s"


def get_status():
    rc, out, err = ai_lab(["status", "--json"], READ_TIMEOUT)
    if rc != 0:
        raise RuntimeError(err or out or f"ai-lab status exit {rc}")
    return json.loads(out)


class Handler(BaseHTTPRequestHandler):
    server_version = "ailab-api/" + VERSION

    def log_message(self, fmt, *a):
        sys.stderr.write(f"api {self.client_address[0]} {fmt % a}\n")

    def _send(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _send_html(self, code, html_body):
        body = html_body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _vscode_page(self, title, inner):
        return ("<!doctype html><meta charset=utf-8>"
                f"<title>{vscode_pr_api.html.escape(title)} — AI Lab VS Code PR box</title>"
                "<style>body{font-family:sans-serif;max-width:42rem;margin:3rem auto;"
                "background:#14161a;color:#e6e6e6}a{color:#7cc7ff}"
                "input,select{padding:.4rem;margin:.2rem 0}"
                "button{padding:.6rem 1.2rem;font-size:1rem;background:#2f6feb;color:#fff;"
                "border:0;border-radius:.4rem;cursor:pointer}"
                "code{background:#22262c;padding:.1rem .3rem;border-radius:.25rem}</style>"
                f"<h2>{vscode_pr_api.html.escape(title)}</h2>{inner}")

    def _authed(self):
        if not TOKEN:
            self._send(503, {"ok": False, "error": "no token configured"})
            return False
        h = (self.headers.get("Authorization") or "").encode()
        return hmac.compare_digest(h, ("Bearer " + TOKEN).encode())

    def _body(self):
        """Read a small JSON body; sends the error response itself on failure."""
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            self._send(400, {"ok": False, "error": "bad Content-Length"})
            return None
        if length > 4096:
            self._send(413, {"ok": False, "error": "body too large"})
            return None
        raw = self.rfile.read(length) if length else b"{}"
        try:
            data = json.loads(raw or b"{}")
        except ValueError:
            self._send(400, {"ok": False, "error": "invalid JSON body"})
            return None
        if not isinstance(data, dict):
            self._send(400, {"ok": False, "error": "body must be a JSON object"})
            return None
        return data

    # ── GET: read-only surface ────────────────────────────────────────────
    def do_GET(self):
        u = urlparse(self.path)
        path = u.path.rstrip("/")
        if path == "/healthz":  # registry health probe; carries no state
            return self._send(200, {"ok": True, "service": "ailab-api"})
        if path.startswith("/vscode-pr/"):
            return self._vscode_pr_get(u)
        if not self._authed():
            return self._send(401, {"ok": False, "error": "unauthorized"})
        seg = [p for p in path.split("/") if p]
        q = parse_qs(u.query)
        try:
            if seg == ["api", "v1", "status"]:
                return self._send(200, {"ok": True, "ts": int(time.time()),
                                        "services": get_status()})
            if seg[:3] == ["api", "v1", "info"] and len(seg) == 4:
                return self._name_route(seg[3], ["info"])
            if seg[:3] == ["api", "v1", "url"] and len(seg) == 4:
                return self._name_route(seg[3], ["url"])
            if seg[:3] == ["api", "v1", "switch"] and len(seg) == 4:
                return self._switch_live(seg[3])
            if seg[:4] == ["api", "v1", "plan", "services"] and len(seg) == 6:
                action, name = seg[4], seg[5]
                if action not in PLAN_ACTIONS:
                    return self._send(400, {"ok": False, "error": "plan: start|stop|toggle"})
                return self._name_route(name, [action, "--dry-run"],
                                        key="plan", check_action=False)
            if seg[:4] == ["api", "v1", "plan", "switch"] and len(seg) == 5:
                value = (q.get("value") or [""])[0]
                return self._switch(seg[4], value, dry_run=True)
        except RuntimeError as e:
            return self._send(500, {"ok": False, "error": str(e)})
        return self._send(404, {"ok": False, "error": "not found"})

    def _name_route(self, name, cmd, key="output", check_action=True):
        if not NAME_RE.match(name) or name not in registry_targets():
            return self._send(404, {"ok": False, "error": f"unknown service '{name}'"})
        rc, out, err = ai_lab(cmd + [name] if cmd[-1] != "--dry-run"
                              else [*cmd[:-1], name, "--dry-run"], READ_TIMEOUT)
        if rc != 0:
            return self._send(502, {"ok": False, "exit": rc, "error": err or out})
        return self._send(200, {"ok": True, key: out})

    def _switch(self, target, value, dry_run=False):
        if target not in SWITCH_RE:
            return self._send(404, {"ok": False, "error": "unknown switch target"})
        if not SWITCH_RE[target].match(value):
            return self._send(400, {"ok": False,
                                    "error": f"invalid value for {target}: {value!r}"})
        args = [target, *value.split()]
        if dry_run:
            args.append("--dry-run")
            rc, out, err = ai_lab(args, READ_TIMEOUT)
            body = {"ok": rc == 0, "plan": out or err}
            return self._send(200 if rc == 0 else 502, body)
        rc, out, err = ai_lab(args, MUTATE_TIMEOUT)
        self._audit_post(f"switch {target} {value}", rc)
        if rc != 0:
            return self._send(502, {"ok": False, "exit": rc, "error": err or out})
        return self._send(200, {"ok": True, "output": out, "state": self._row_for(target)})

    def _switch_live(self, target):
        if target not in SWITCH_RE:
            return self._send(404, {"ok": False, "error": "unknown switch target"})
        rc, out, err = ai_lab([target], READ_TIMEOUT)
        if rc != 0:
            return self._send(502, {"ok": False, "exit": rc, "error": err or out})
        return self._send(200, {"ok": True, "value": out})

    def _row_for(self, name):
        try:
            for s in get_status():
                if s["name"] == name or s.get("group") == name:
                    return s
        except RuntimeError:
            pass
        return None

    # ── POST: mutations (arbiter always in the loop) ──────────────────────
    def do_POST(self):
        u = urlparse(self.path)
        if u.path.rstrip("/").startswith("/vscode-pr/"):
            return self._vscode_pr_post(u)
        if not self._authed():
            return self._send(401, {"ok": False, "error": "unauthorized"})
        seg = [p for p in urlparse(self.path).path.rstrip("/").split("/") if p]
        if seg[:3] == ["api", "v1", "services"] and len(seg) == 5:
            name, action = seg[3], seg[4]
            if action not in ACTIONS:
                return self._send(400, {"ok": False, "error": "action: start|stop|toggle|restart"})
            if not NAME_RE.match(name) or name not in registry_targets():
                return self._send(404, {"ok": False, "error": f"unknown service '{name}'"})
            return self._mutate([action, name], f"{action} {name}")
        if seg[:3] == ["api", "v1", "switch"] and len(seg) == 4:
            data = self._body()
            if data is None:
                return None
            value = str(data.get("value", ""))
            return self._switch(seg[3], value)
        return self._send(404, {"ok": False, "error": "not found"})

    def _vscode_pr_get(self, u):
        """Signed browser routes (NOT bearer): the review-button interstitial
        and the token-access page. Both verified via HMAC+exp."""
        seg = [p for p in u.path.rstrip("/").split("/")[2:]]  # drop /vscode-pr
        q = parse_qs(u.query)
        exp = (q.get("exp") or [""])[0]
        sig = (q.get("sig") or [""])[0]
        e = vscode_pr_api.configured()
        if e:
            return self._send_html(503, self._vscode_page("VS Code PR box", f"<p>{e}</p>"))
        if len(seg) == 3 and all(seg):
            owner, repo, pr = seg
            err = vscode_pr_api.check_sig("launch", f"{owner}/{repo}", pr, exp, sig)
            if err:
                return self._send_html(403, self._vscode_page("VS Code PR box", f"<p>{err}</p>"))
            title, author = vscode_pr_api.pr_title(owner, repo, pr)
            slug = vscode_pr_api.slug_for(owner, repo, pr)
            st = vscode_pr_api.env_state(slug)
            if st:
                inner = (f"<p>An environment for <code>{owner}/{repo}#{pr}</code> already "
                         f"exists (port <code>{st.get('port')}</code>). Open its "
                         f"<a href='/vscode-pr/{owner}/{repo}/{pr}/access?exp={exp}&sig={sig}'>access page</a> or "
                         "run the <b>-down</b> pipeline first.</p>")
                return self._send_html(200, self._vscode_page("VS Code PR box", inner))
            who = vscode_pr_api.html.escape(author or "")
            inner = (
                f"<p>PR: <b>{vscode_pr_api.html.escape(title or f'{owner}/{repo}#{pr}')}</b><br>"
                "A dedicated code-server box for this change will be spun up by a pair of "
                "Concourse pipelines: a <b>-up</b> pipeline (generates + registers a "
                "read-only SSH deploy key scoped to this change, starts the container, "
                "comments the PR) and a paused <b>-down</b> pipeline (removes the "
                "container and revokes the temporary credential).</p>"
                "<p>The box's <code>git</code> identity comes from the Forgejo account "
                "you launch as — <b>name the forge user that is triggering this</b>:</p>"
                f"<form method='post'>"
                f"<input type='hidden' name='exp' value='{exp}'>"
                f"<input type='hidden' name='sig' value='{sig}'>"
                f"<input name='user' placeholder='forge username' value='{who}' required>"
                " <button type='submit'>Spin up VS Code environment</button></form>"
                "<p style='opacity:.7'>Link valid until "
                f"{time.strftime('%Y-%m-%d %H:%M UTC', time.gmtime(int(exp or 0)))}.</p>")
            return self._send_html(200, self._vscode_page("Launch VS Code review box", inner))
        if len(seg) == 4 and seg[3] == "access":
            owner, repo, pr = seg[:3]
            err = vscode_pr_api.check_sig("access", f"{owner}/{repo}", pr, exp, sig)
            if err:
                return self._send_html(403, self._vscode_page("VS Code PR box", f"<p>{err}</p>"))
            slug = vscode_pr_api.slug_for(owner, repo, pr)
            st = vscode_pr_api.env_state(slug)
            if not st:
                return self._send_html(404, self._vscode_page("VS Code PR box",
                                                              "<p>No environment for this PR (destroyed?).</p>"))
            tokf = os.path.join(vscode_pr_api.STATE_ROOT, slug, "token")
            token = open(tokf).read().strip() if os.path.isfile(tokf) else ""
            door = vscode_pr_api.CFG["VSCODE_PR_DOOR_BASE"].rstrip("/") \
                + f":{8450 + (int(st['port']) - 3130)}"
            inner = (f"<p>Environment <code>{slug}</code> — reviewer identity baked in: "
                     f"<code>{vscode_pr_api.html.escape(st.get('git_name',''))} "
                     f"&lt;{vscode_pr_api.html.escape(st.get('git_email',''))}&gt;</code></p>"
                     f"<p><a href='{door}/'>Open the box</a> — code-server asks for a password; paste this:</p>"
                     f"<p>Connection password: <code>{token}</code></p>"
                     "<p>Teardown: unpause + trigger the <b>-down</b> pipeline in the Concourse UI.</p>")
            return self._send_html(200, self._vscode_page("VS Code review box", inner))
        return self._send_html(404, self._vscode_page("VS Code PR box", "<p>not found</p>"))

    def _vscode_pr_post(self, u):
        seg = [p for p in u.path.rstrip("/").split("/")[2:]]  # drop /vscode-pr
        if not (len(seg) == 3 and all(seg)):
            return self._send_html(404, self._vscode_page("VS Code PR box", "<p>not found</p>"))
        owner, repo, pr = seg
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length > 4096:
            return self._send_html(413, self._vscode_page("VS Code PR box", "<p>body too large</p>"))
        form = parse_qs(self.rfile.read(length).decode(errors="replace")) if length else {}
        exp = (form.get("exp") or [""])[0]
        sig = (form.get("sig") or [""])[0]
        user = (form.get("user") or [""])[0].strip()
        err = vscode_pr_api.check_sig("launch", f"{owner}/{repo}", pr, exp, sig)
        if err:
            return self._send_html(403, self._vscode_page("VS Code PR box", f"<p>{err}</p>"))
        if not user or not re.match(r"^[A-Za-z0-9._-]{1,64}$", user):
            return self._send_html(400, self._vscode_page("VS Code PR box",
                                                          "<p>provide a valid forge username</p>"))
        ok, msg, info = vscode_pr_api.launch(owner, repo, pr, user)
        if not ok:
            return self._send_html(400, self._vscode_page("VS Code PR box",
                                                          f"<p>{vscode_pr_api.html.escape(msg)}</p>"))
        cu = vscode_pr_api.CFG.get("VSCODE_PR_CONCOURSE_PUBLIC") or vscode_pr_api.CFG["VSCODE_PR_CONCOURSE_URL"]
        inner = (f"<p>Created and triggered:</p><ul>"
                 f"<li><a href='{cu}/teams/main/pipelines/{info['up']}/jobs/create'>{info['up']}</a> — "
                 "registers the change-scoped SSH key, boots the box, comments the PR</li>"
                 f"<li><a href='{cu}/teams/main/pipelines/{info['down']}/jobs/destroy'>{info['down']}</a> — "
                 "<b>paused</b>; unpause + trigger to destroy</li></ul>"
                 f"<p>Reviewer identity: <code>{info['git_name']} &lt;{info['git_email']}&gt;</code> "
                 f"(forge user <code>{user}</code>) — port <code>{info['port']}</code>.</p>"
                 f"<p><a href='/vscode-pr/{owner}/{repo}/{pr}/access?exp={exp}&sig={sig}'>access page</a></p>")
        return self._send_html(200, self._vscode_page("VS Code review environment launched", inner))

    def _mutate(self, args, label):
        global _last_mutate
        with LOCK:
            now = time.monotonic()
            if now - _last_mutate < MIN_MUTATE_GAP:
                return self._send(429, {"ok": False, "error": "mutation rate limit"})
            rc, out, err = ai_lab(args, MUTATE_TIMEOUT)
            _last_mutate = time.monotonic()   # gap measured after completion
            self._audit_post(label, rc)
            if rc != 0:
                return self._send(502, {"ok": False, "exit": rc, "error": err or out})
            name = args[1]
            return self._send(200, {"ok": True, "output": out, "state": self._row_for(name)})

    def _audit_post(self, label, rc):
        sys.stderr.write(f"audit {self.client_address[0]} POST {label} -> rc={rc}\n")

    def do_OPTIONS(self):
        self._send(405, {"ok": False, "error": "method not allowed"})


def main():
    if not TOKEN:
        sys.stderr.write("ailab-api: AILAB_API_TOKEN is unset — refusing to start "
                         "unauthenticated (run scripts/generate-secrets.sh)\n")
        return 1
    if not os.access(AILAB, os.X_OK):
        sys.stderr.write(f"ailab-api: {AILAB} not found/executable (AI_LAB_REPO wrong?)\n")
        return 1
    if not os.path.isfile(REGISTRY):
        sys.stderr.write(f"ailab-api: registry not found at {REGISTRY}\n")
        return 1
    srv = ThreadingHTTPServer((BIND, PORT), Handler)
    srv.daemon_threads = True
    sys.stderr.write(f"ailab-api {VERSION} listening on http://{BIND}:{PORT} "
                     f"(repo={REPO})\n")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
