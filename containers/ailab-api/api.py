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
