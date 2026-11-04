#!/usr/bin/env bash
set -euo pipefail

: "${VSCODE_CONNECTION_TOKEN:?set via EnvironmentFile (config/vscode/service.env)}"

# Guest podman -> host daemon (image ships containers.conf remote=true; the
# socket is mounted by the quadlet at the host's same path). Register the
# connection once; it then lives in the persisted home.
if ! podman system connection list 2>/dev/null | grep -q 'unix:///run/user/1000/podman/podman.sock'; then
  podman system connection add --default host unix:///run/user/1000/podman/podman.sock
fi

# ---------------------------------------------------------------------------
# Copilot/Chat -> strata binding (v2, 2026-11-04).
#
# Models reach the picker through the STABLE LanguageModelChatProvider API via
# a provider extension baked into the image at /opt/vscode/extensions/
# strata-provider (source: containers/vscode/strata-provider). It discovers
# models live from the server's GET /models (id, meta.n_ctx, modalities), reads
# STRATA_API_KEY from the environment (EnvironmentFile), and keeps its defaults
# in package.json -- no user-scoped data files are seeded or merged, and strata
# re-slots are picked up automatically on next picker refresh.
#
# The previous implementation (first-start heredoc into
# data/User/chatLanguageModels.json + jq-merge of data/User/settings.json) was
# removed: user-scope files are UI-owned state, and a first-start-only seed
# silently drifts (diverged edits, stale model ids -- both happened). Two
# layers now:
#   * models: the extension (image-baked, git-tracked, idempotent install)
#   * box policy: data/Machine/settings.json (SERVER scope, verified
#     machineSettingsResource in the 1.144.1 server bundle; written wholesale
#     each start; overrides user scope; not touched by any settings UI).
# ---------------------------------------------------------------------------

SRC=/opt/vscode/extensions/strata-provider
if [ -d "$SRC" ]; then
  EXTDIR="$HOME/.vscode-server/extensions"
  ver=$(sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$SRC/package.json" | head -1)
  dest="$EXTDIR/dark5un.strata-provider-${ver}"
  if [ ! -d "$dest" ]; then
    mkdir -p "$EXTDIR"
    cp -a "$SRC" "$dest"
    # retire older copies of our extension (single registration only)
    for old in "$EXTDIR"/dark5un.strata-provider-*; do
      [ -d "$old" ] && [ "$old" != "$dest" ] && rm -rf "$old"
    done
    echo "installed strata-provider ${ver} into $EXTDIR"
  fi
fi

# Agent Host gates (1.14x: chat runs on the Copilot harness through the Agent
# Host; BYOK models are hidden from it unless byokModelsEnabled -- confirmed
# chat.agentHost.byokModels.enabled in the 1.144.1 workbench bundle, default
# false). allowSignedOutWhenUsable keeps the box usable with no GitHub sign-in;
# byokUtilityModelDefault routes titles/commit-messages to the main agent
# model (the local one) instead of the Copilot utility backend.
MACHINE="$HOME/.vscode-server/data/Machine"
mkdir -p "$MACHINE"
cat > "$MACHINE/settings.json" <<'JSON'
{
  "chat.agentHost.byokModels.enabled": true,
  "chat.agentHost.allowSignedOutWhenUsable": true,
  "chat.byokUtilityModelDefault": "mainAgent"
}
JSON

exec code serve-web \
  --host 0.0.0.0 --port 8000 \
  --connection-token "$VSCODE_CONNECTION_TOKEN" \
  --accept-server-license-terms \
  --disable-telemetry
