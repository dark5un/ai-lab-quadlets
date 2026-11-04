#!/usr/bin/env bash
set -euo pipefail

: "${VSCODE_CONNECTION_TOKEN:?set via EnvironmentFile (config/vscode/service.env)}"

# Guest podman -> host daemon (image ships containers.conf remote=true; the
# socket is mounted by the quadlet at the host's same path). Register the
# connection once; it then lives in the persisted home.
if ! podman system connection list 2>/dev/null | grep -q 'unix:///run/user/1000/podman/podman.sock'; then
  podman system connection add --default host unix:///run/user/1000/podman/podman.sock
fi

# Copilot BYOK -> strata: seed VS Code's Custom Endpoint provider into the
# persisted user config (first start only; after that the box owns the file
# and edits from the Manage Language Models UI win). Key comes from
# EnvironmentFile (config/vscode/service.env STRATA_API_KEY), never from
# the image or the repo. STRATA_URL/STRATA_MODEL are overridable for when
# strata re-slots or the model id changes.
STRATA_URL="${STRATA_URL:-http://systemd-strata:8080/v1/chat/completions}"
STRATA_MODEL="${STRATA_MODEL:-qwen3.8-flash-next-iq3_s}"
CLM="$HOME/.vscode-server/data/User/chatLanguageModels.json"
if [ -n "${STRATA_API_KEY:-}" ] && [ ! -f "$CLM" ]; then
  mkdir -p "$(dirname "$CLM")"
  umask 077
  cat > "$CLM" <<JSON
[
  {
    "name": "strata",
    "vendor": "customendpoint",
    "apiKey": "${STRATA_API_KEY}",
    "apiType": "chat-completions",
    "models": [
      {
        "id": "${STRATA_MODEL}",
        "name": "Strata (local 5090)",
        "url": "${STRATA_URL}",
        "toolCalling": true,
        "vision": true,
        "thinking": true,
        "contextWindow": 1048576,
        "maxOutputTokens": 16384
      }
    ]
  }
]
JSON
  echo "seeded $CLM (strata BYOK; edit via Chat: Manage Language Models)"
fi

# Agent Host chat sessions (the default since the 1.14x agents UX) hide
# BYOK models unless chat.agentHost.byokModels.enabled is true (default
# false) -- without it, selecting strata silently falls back to Auto/Copilot.
# Seed/add the key; never override an explicit user choice.
SET="$HOME/.vscode-server/data/User/settings.json"
if [ ! -f "$SET" ]; then
  printf '{\n  "chat.agentHost.byokModels.enabled": true\n}\n' > "$SET"
elif command -v jq >/dev/null && ! grep -q 'agentHost.byokModels' "$SET"; then
  tmp=$(mktemp)
  if jq '. + {"chat.agentHost.byokModels.enabled": true}' "$SET" > "$tmp" 2>/dev/null; then
    cat "$tmp" > "$SET"; echo "settings.json: enabled chat.agentHost.byokModels.enabled"
  fi
  rm -f "$tmp"
fi

exec code serve-web \
  --host 0.0.0.0 --port 8000 \
  --connection-token "$VSCODE_CONNECTION_TOKEN" \
  --accept-server-license-terms \
  --disable-telemetry
