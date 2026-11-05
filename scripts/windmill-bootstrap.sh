#!/usr/bin/env bash
# windmill-bootstrap.sh — headless first-boot setup for the Windmill instance
# (windmill-jupyter plan P0 gate: 'admin login; hello webhook runs').
#
# A fresh CE install has NO seeded user (verified live on 1.862.0: the
# docs' admin@windmill.dev/changeme login 400s against an empty usr table).
# The bootstrap path is the SUPERADMIN_SECRET bearer token (acts as the
# virtual superadmin superadmin@windmill.dev, per official env-var docs):
#   1. create the real instance admin  (POST /api/users/create)
#   2. create the 'kb' workspace       (POST /api/workspaces/create)
#   3. login as the new admin, mint a full-scope agent token
#      (POST /api/users/tokens/create) -> stored in
#      $AI_LAB_CONFIG_DIR/windmill/agent-token (mode 600, never printed)
#   4. keep the existing default-superadmin login disabled: with a real
#      admin created, the wizard state is satisfied.
#
# Idempotent: re-running when everything exists is a no-op (409s tolerated).
# Secrets handling: reads SUPERADMIN_SECRET and the chosen admin password
# from local files; no secret VALUE ever appears in this script or argv.
set -euo pipefail

CONF="${AI_LAB_CONFIG_DIR:-${HOME}/.config/containers/config}"
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

ADMIN_EMAIL="${WM_ADMIN_EMAIL:-panos@ai.local}"
WS_NAME="${WM_WORKSPACE:-kb}"

python3 - "$CONF" "$ADMIN_EMAIL" "$WS_NAME" <<'PYEOF'
import json, os, sys, urllib.request, pathlib, secrets, stat

conf, admin_email, ws_name = sys.argv[1:4]
envf = pathlib.Path(conf) / "windmill" / "service.env"
base = "http://127.0.0.1:3117"
supersecret = None
for line in envf.read_text().splitlines():
    if line.startswith("SUPERADMIN_SECRET="):
        supersecret = line.split("=", 1)[1].strip()
assert supersecret, "SUPERADMIN_SECRET empty - run generate-secrets.sh"

# admin password: generated once, persisted next to the env (600)
pwf = pathlib.Path(conf) / "windmill" / "admin-password.txt"
if not pwf.exists():
    pwf.write_text(secrets.token_urlsafe(18) + "Aa1")
    os.chmod(pwf, 0o600)
admin_pw = pwf.read_text().strip()

def api(method, path, body=None, token=None, allow=(200, 201)):
    req = urllib.request.Request(base + "/api" + path, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    data = json.dumps(body).encode() if body is not None else None
    try:
        r = urllib.request.urlopen(req, data=data, timeout=30)
        raw = r.read().decode()
        if "json" in (r.headers.get("content-type") or ""):
            return r.status, json.loads(raw)
        return r.status, raw
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        if e.code == 409:
            return 409, raw
        raise RuntimeError(f"{method} {path}: {e.code} {raw[:200]}")

# 1. create the instance admin (re-run surfaces 400 'already exists')
try:
    st, _ = api("POST", "/users/create",
                {"email": admin_email, "name": admin_email.split("@")[0],
                 "password": admin_pw, "super_admin": True}, token=supersecret)
    print("users/create:", st)
except RuntimeError as e:
    assert "already exists" in str(e), e
    print("users/create: exists")

# 2. create the workspace (CreateWorkspace requires id + name)
try:
    st, _ = api("POST", "/workspaces/create", {"id": ws_name, "name": ws_name}, token=supersecret)
    print("workspaces/create:", st)
except RuntimeError as e:
    assert "already exists" in str(e), e
    print("workspaces/create: exists")

# 2b. membership: instance-level users are NOT auto-added to workspaces
# (usr rows are per-workspace; verified live) - add as workspace admin.
try:
    st, _ = api("POST", f"/w/{ws_name}/workspaces/add_user",
                {"email": admin_email, "is_admin": True, "operator": False},
                token=supersecret)
    print("add_user:", st)
except RuntimeError as e:
    assert "already" in str(e), e
    print("add_user: exists")

# 3. login as the new admin (response is PLAINTEXT token) + mint agent token
# reuse the stored token if it still authenticates (rerun must not orphan one)
tokf = pathlib.Path(conf) / "windmill" / "agent-token"
token_value = tokf.read_text().strip() if tokf.exists() else None
st = 0
if token_value:
    try:
        st, me = api("GET", f"/w/{ws_name}/users/whoami", token=token_value)
    except RuntimeError:
        st = 0
if st != 200:
    token_value = None
if not token_value:
    st, jwt = api("POST", "/auth/login", {"email": admin_email, "password": admin_pw})
    assert st == 200 and jwt, "login failed"
    st, agent = api("POST", "/users/tokens/create",
                    {"label": "hermes-agent", "expiration": None,
                     "scopes": [], "workspace_id": ws_name, "read_only": False}, token=jwt)
    token_value = agent if isinstance(agent, str) else agent["token"]  # 1.862 returns plaintext
    tokf.write_text(token_value + "\n")
    os.chmod(tokf, 0o600)
    print("agent token written ->", tokf)
else:
    print("agent token reused ->", tokf)

# 4. verify the token: workspace-scoped tokens CANNOT call instance-level
# routes (401 on /workspaces/list; verified live) - check /w/{ws}/users/whoami.
st, me = api("GET", f"/w/{ws_name}/users/whoami", token=token_value)
assert st == 200 and me.get("email") == admin_email, f"whoami failed: {st} {me}"
print("whoami ok:", me["email"], "admin:", me["is_admin"])
print("bootstrap OK")
PYEOF
