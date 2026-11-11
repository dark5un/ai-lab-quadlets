#!/usr/bin/env bash
# ragflow-fix-admin-password.sh — manage the admin@ragflow.io password trio:
#   config/ragflow/.admin_pw_once  +  ADMIN_DEFAULT_PASSWORD in service.env
#   +  the stored hash in the rag_flow MySQL user table.
#
# Modes:
#   (default)   re-hash the RECORDED file password into the DB (drift repair).
#   --rotate    generate a NEW password: write .admin_pw_once, sync
#               ADMIN_DEFAULT_PASSWORD in service.env, update the DB hash.
#
# Why: RAGFlow v1.0.0-rc3 (Go server) stores passwords in werkzeug format
#   scrypt:32768:8:1$base64(12 random bytes)$hex(64)
# (internal/common/password.go::GenerateWerkzeugPasswordHash — verified against
# the live user table). The init flow only sets the admin password on FIRST
# boot, so file/DB drift happens. Proof of the write is a DB read-back, NOT a
# login attempt: owner directive 2026-11-11 — the agent must not use admin
# credentials, and every extra login mutates last_login state the owner may
# rely on.
#
# CAUTION for future agents: a DB-vs-file mismatch is NOT automatically drift —
# it may be the owner's deliberate custom password. Ask before repairing.
#
# Reads every secret from the config files itself; never prints values.
set -euo pipefail
CONF="${AI_LAB_CONFIG_DIR:-$HOME/.config/containers/config}"
MODE="repair"
[ "${1:-}" = "--rotate" ] && MODE="rotate"

python3 - "$CONF" "$MODE" <<'PYEOF'
import base64, hashlib, os, pathlib, re, secrets as pysecrets, subprocess, sys

conf, mode = pathlib.Path(sys.argv[1]) / "ragflow", sys.argv[2]
pwfile = conf / ".admin_pw_once"

def envval(p, key):
    for line in pathlib.Path(p).read_text().splitlines():
        if line.startswith(key + "="):
            return line.split("=", 1)[1].strip().strip('"')
    return ""

def set_env_key(p, key, value):
    lines = pathlib.Path(p).read_text().splitlines()
    lines = [f"{key}={value}" if l.startswith(key + "=") else l for l in lines]
    pathlib.Path(p).write_text("\n".join(lines) + "\n")
    os.chmod(p, 0o600)

if mode == "rotate":
    # RAGFlow-safe random: 32 hex chars, same shape generate-secrets uses
    newpw = pysecrets.token_hex(16)
    pwfile.write_text(newpw + "\n")
    os.chmod(pwfile, 0o600)
    set_env_key(conf / "service.env", "ADMIN_DEFAULT_PASSWORD", newpw)
    print("rotated: .admin_pw_once + ADMIN_DEFAULT_PASSWORD synced")

pw = pwfile.read_text().strip()
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

# proof: read-back of the row's format/length (the password itself is never used)
r2 = subprocess.run(["podman", "exec", "systemd-ragflow-mysql", "sh", "-c",
                     f"mysql -uroot -p'{mysql_pw}' rag_flow -N -B -e \"select substring_index(password,'\\$',1), length(password) from user where email='admin@ragflow.io'\""],
                    capture_output=True, text=True)
out = r2.stdout.strip()
if not re.match(r"^scrypt:32768:8:1\t162$", out):
    sys.exit(f"DB read-back unexpected: {out!r}")
print("password row updated + read-back verified (no login attempted)")
PYEOF
