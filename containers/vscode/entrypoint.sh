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
  # jq, not sed: first "version" string anywhere in package.json could be a
  # dependency's (review finding #8).
  ver=$(jq -r .version "$SRC/package.json")
  dest="$EXTDIR/dark5un.openai-compatible-models-${ver}"
  mkdir -p "$EXTDIR"
  if [ ! -d "$dest" ]; then
    cp -a "$SRC" "$dest"
    # retire older copies of our extension (single registration only); the
    # strata-provider glob covers the pre-rename (0.1.x) installs.
    for old in "$EXTDIR"/dark5un.openai-compatible-models-* "$EXTDIR"/dark5un.strata-provider-*; do
      [ -d "$old" ] && [ "$old" != "$dest" ] && rm -rf "$old"
    done
    echo "installed openai-compatible-models ${ver} into $EXTDIR"
  fi
  # Register in the profile manifest (extensions.json) -- the manifest is the
  # authoritative installed set; folders merely present on disk get GC'd into
  # .obsolete by extension sync (observed live in 1.144.1). Re-arm our entry
  # every start; drop our legacy id (dark5un.strata-provider) and any other
  # entries are left untouched. Manifest shape mirrors gallery-installed
  # entries.
  MANIFEST="$EXTDIR/extensions.json"
  [ -f "$MANIFEST" ] || echo '[]' > "$MANIFEST"
  now=$(date +%s%3N)
  entry=$(jq -n --arg id "dark5un.openai-compatible-models" --arg ver "$ver" \
    --arg dir "dark5un.openai-compatible-models-${ver}" --arg path "$dest" --argjson ts "$now" \
    '{identifier:{id:$id},version:$ver,location:{"$mid":1,path:$path,scheme:"file"},
      relativeLocation:$dir,
      metadata:{installedTimestamp:$ts,pinned:true,source:"vsix",
        isBuiltin:false,isPreReleaseVersion:false,hasPreReleaseVersion:false}}' 2>/dev/null || true)
  tmp=$(mktemp)
  if [ -n "$entry" ] && jq -c --arg id "dark5un.openai-compatible-models" --arg legacy "dark5un.strata-provider" \
       --argjson e "$entry" \
       '[ .[] | select(.identifier.id != $id and .identifier.id != $legacy) ] + [$e]' "$MANIFEST" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$MANIFEST"
  else
    rm -f "$tmp"; echo "WARN: could not update $MANIFEST" >&2
  fi
  if [ -f "$EXTDIR/.obsolete" ]; then
    tmp=$(mktemp)
    if jq -c 'with_entries(select(.key | startswith("dark5un.") | not))' \
         "$EXTDIR/.obsolete" > "$tmp" 2>/dev/null; then mv "$tmp" "$EXTDIR/.obsolete"; else rm -f "$tmp"; fi
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
  "chat.byokUtilityModelDefault": "mainAgent",
  "strata.baseUrl": "http://systemd-strata:8080/v1"
}
JSON
# Note: workspace trust is intentionally left ON. First open of the default
# folder in a new browser asks once ("Trust Workspace"); that click persists
# per browser. The chat model picker is disabled while a workspace is
# untrusted (verified headless) -- by design, not a config gap.

# --default-folder: the box's own work area -- host ~/.workspaces/vscode
# mounted at ~/workspace inside the container (the ~/workspace convention;
# see quadlets/vscode.container). An empty workspace hides the agent-mode
# chat input entirely (verified headless).
mkdir -p "$HOME/workspace"
# Connection token via FILE, never argv (review finding #1): argv is visible
# to every process in the container (ps, /proc/*/cmdline) and to any exec
# audit. The env var stays the EnvironmentFile delivery; this file lands in
# the persisted home with 0600 and is rewritten each start (rotation-safe).
# The one-time startup banner in the journal still shows ?tkn=; if ever
# suspected, rotate via scripts/rotate-secrets.sh.
umask 077
mkdir -p "$HOME/.vscode-server"
printf '%s' "$VSCODE_CONNECTION_TOKEN" > "$HOME/.vscode-server/connection-token"
exec code serve-web \
  --host 0.0.0.0 --port 8000 \
  --default-folder "$HOME/workspace" \
  --connection-token-file "$HOME/.vscode-server/connection-token" \
  --accept-server-license-terms \
  --disable-telemetry
