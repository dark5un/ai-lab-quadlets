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
  mkdir -p "$EXTDIR"
  if [ ! -d "$dest" ]; then
    cp -a "$SRC" "$dest"
    # retire older copies of our extension (single registration only)
    for old in "$EXTDIR"/dark5un.strata-provider-*; do
      [ -d "$old" ] && [ "$old" != "$dest" ] && rm -rf "$old"
    done
    echo "installed strata-provider ${ver} into $EXTDIR"
  fi
  # Register in the profile manifest (extensions.json) -- the manifest is the
  # authoritative installed set; folders merely present on disk get GC'd into
  # .obsolete by extension sync (observed live in 1.144.1). Re-arm our entry
  # every start; leave all other entries untouched. Drop any .obsolete marks
  # for our id. Manifest shape mirrors gallery-installed entries.
  MANIFEST="$EXTDIR/extensions.json"
  [ -f "$MANIFEST" ] || echo '[]' > "$MANIFEST"
  now=$(date +%s%3N)
  entry=$(jq -n --arg id "dark5un.strata-provider" --arg ver "$ver" \
    --arg dir "dark5un.strata-provider-${ver}" --arg path "$dest" --argjson ts "$now" \
    '{identifier:{id:$id},version:$ver,location:{"$mid":1,path:$path,scheme:"file"},
      relativeLocation:$dir,
      metadata:{installedTimestamp:$ts,pinned:true,source:"vsix",
        isBuiltin:false,isPreReleaseVersion:false,hasPreReleaseVersion:false}}' 2>/dev/null || true)
  tmp=$(mktemp)
  if [ -n "$entry" ] && jq -c --arg id "dark5un.strata-provider" --argjson e "$entry" \
       '[ .[] | select(.identifier.id != $id) ] + [$e]' "$MANIFEST" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$MANIFEST"
  else
    rm -f "$tmp"; echo "WARN: could not update $MANIFEST" >&2
  fi
  if [ -f "$EXTDIR/.obsolete" ]; then
    tmp=$(mktemp)
    if jq -c 'with_entries(select(.key | startswith("dark5un.strata-provider") | not))' \
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
  "chat.byokUtilityModelDefault": "mainAgent"
}
JSON
# Note: workspace trust is intentionally left ON. First open of the default
# folder in a new browser asks once ("Trust Workspace"); that click persists
# per browser. The chat model picker is disabled while a workspace is
# untrusted (verified headless) -- by design, not a config gap.

# --default-folder: the box's own work area (same-path mount); an empty
# workspace hides the agent-mode chat input entirely (verified headless).
mkdir -p "$HOME/.workspaces/vscode"
exec code serve-web \
  --host 0.0.0.0 --port 8000 \
  --default-folder "$HOME/.workspaces/vscode" \
  --connection-token "$VSCODE_CONNECTION_TOKEN" \
  --accept-server-license-terms \
  --disable-telemetry
