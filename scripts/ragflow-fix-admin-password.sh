#!/usr/bin/env bash
# ragflow-fix-admin-password.sh — reset admin@ragflow.io's stored password to
# the recorded config value (config/ragflow/.admin_pw_once == the
# ADMIN_DEFAULT_PASSWORD in service.env; they are generated in lockstep by
# generate-secrets.sh).
#
# Why this exists: RAGFlow v1.0.0-rc3 (Go server) hashes passwords in the
# werkzeug-compatible format  scrypt:32768:8:1$base64(12 random bytes)$hex(64)
# (internal/common/password.go::GenerateWerkzeugPasswordHash — verified
# against the live user table). The init flow only sets the admin password on
# FIRST boot, so any drift (failed init, DB restored from an older volume,
# in-place upgrade) leaves .admin_pw_once pointing at a password the DB never
# got. The account cannot console-login by design (POST /api/v1/auth/login ->
# "super admin should not login to this page"); the ADMIN API route
# /api/v1/admin/login is the real proof.
#
# Reads every secret from the config files itself; never prints values.
set -euo pipefail
CONF="${AI_LAB_CONFIG_DIR:-$HOME/.config/containers/config}"

python3 - "$CONF" <<'PYEOF'
import base64, hashlib, json, os, pathlib, secrets as pysecrets, subprocess, sys, urllib.request, urllib.error

conf = pathlib.Path(sys.argv[1]) / "ragflow"
pw = (conf / ".admin_pw_once").read_text().strip()

def envval(p, key):
    for line in pathlib.Path(p).read_text().splitlines():
        if line.startswith(key + "="):
            return line.split("=", 1)[1].strip().strip('"')
    return ""

mysql_pw = envval(conf / "mysql.env", "MYSQL_ROOT_PASSWORD")
salt = base64.b64encode(pysecrets.token_bytes(12)).decode()
dk = hashlib.scrypt(pw.encode(), salt=salt.encode(), n=32768, r=8, p=1, dklen=64, maxmem=64*1024*1024)
newhash = f"scrypt:32768:8:1${salt}${dk.hex()}"

sql = f"UPDATE user SET password='{newhash}' WHERE email='admin@ragflow.io';\n"
r = subprocess.run(["podman", "exec", "systemd-ragflow-mysql", "sh", "-c",
                    f"mysql -uroot -p'{mysql_pw}' rag_flow < /dev/stdin"],
                   input=sql, capture_output=True, text=True)
if r.returncode != 0:
    sys.exit("mysql update failed (is systemd-ragflow-mysql up?)")
print("password row updated")

# proof: the admin API login the /admin console uses
req = urllib.request.Request("http://127.0.0.1:3114/api/v1/admin/login",
                             method="POST", data=json.dumps(
    {"email": "admin@ragflow.io", "password": pw}).encode(),
    headers={"Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=20) as resp:
        body = resp.read().decode()
    print("admin login:", "OK" if '"code":0' in body else f"UNEXPECTED {body[:120]}")
except urllib.error.HTTPError as e:
    sys.exit(f"admin login FAILED: {e.code} {e.read().decode()[:150]}")
PYEOF
