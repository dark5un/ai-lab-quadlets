#!/usr/bin/env bash
set -euo pipefail

: "${VSCODE_CONNECTION_TOKEN:?set via EnvironmentFile (config/vscode/service.env)}"

# Guest podman -> host daemon (image ships containers.conf remote=true; the
# socket is mounted by the quadlet at the host's same path). Register the
# connection once; it then lives in the persisted home.
if ! podman system connection list 2>/dev/null | grep -q 'unix:///run/user/1000/podman/podman.sock'; then
  podman system connection add --default host unix:///run/user/1000/podman/podman.sock
fi

exec code serve-web \
  --host 0.0.0.0 --port 8000 \
  --connection-token "$VSCODE_CONNECTION_TOKEN" \
  --accept-server-license-terms \
  --disable-telemetry
