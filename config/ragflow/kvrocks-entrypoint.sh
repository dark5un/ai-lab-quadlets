#!/bin/sh
# Kvrocks entrypoint for the RAGFlow cache service — carried from upstream
# infiniflow/ragflow docker/kvrocks-entrypoint.sh (v1.0.0-rc3, Apache-2.0).
#
# Kvrocks 2.16.0 does NOT support ${ENV} expansion inside its config file and
# rejects `--requirepass` as a CLI flag (gflags intercepts the config key
# before Kvrocks' own handler runs). To preserve the password-based auth
# without committing the secret, we render the config from the REDIS_PASSWORD
# environment variable (injected via EnvironmentFile) at container start.
#
# Config keys verified against apache/kvrocks:2.16.0:
#   bind, port, dir, requirepass
# Intentionally omitted (invalid in kvrocks 2.16.0): maxmemory, maxmemory-policy.
set -eu

# REDIS_PASSWORD is mandatory: an unauthenticated cache/queue backend is a
# security exposure. Refuse to start rather than silently run open.
: "${REDIS_PASSWORD:?REDIS_PASSWORD must be set (inject via EnvironmentFile or -e)}"

# KVROCKS_DIR overrides the RocksDB data/config dir (defaults to the volume
# mount point). Test harnesses use it to redirect writes to a temp dir.
KVROCKS_DIR="${KVROCKS_DIR:-/var/lib/kvrocks}"
mkdir -p "$KVROCKS_DIR"

{
  echo "bind 0.0.0.0"
  echo "port 6379"
  echo "dir $KVROCKS_DIR"
  printf 'requirepass %s\n' "$REDIS_PASSWORD"
} > "$KVROCKS_DIR/kvrocks.conf"

exec kvrocks -c "$KVROCKS_DIR/kvrocks.conf" --dir "$KVROCKS_DIR"
