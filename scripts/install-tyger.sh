#!/usr/bin/env bash
# install-tyger.sh - build the tyger-s2s image and render its quadlet.
#
#   ./scripts/install-tyger.sh             build the image if missing, render the unit
#   ./scripts/install-tyger.sh --rebuild   rebuild the image from the clone first
#
# The image is tagged with the clone's commit (localhost/tyger-s2s-v1:<short sha>),
# and the unit mounts the clone itself, so config, prompt and voice edits are a
# restart, not a rebuild. Nothing is started here: `ai-lab start tyger-s2s`.
#
# The clone carries the fork's V02 (hermes shim plugin) and V06 (persona) commits and
# is NOT upstream main. Set TYGER_REPO to point elsewhere.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TYGER_REPO="${TYGER_REPO:-${HOME}/workspace/github.com/nineninesix-ai/tyger-s2s}"
UNIT="tyger-s2s"
IMAGE_REPO="localhost/tyger-s2s-v1"
ENV_FILE="${HOME}/.local/share/ai-lab/tyger/tyger.env"
REBUILD=0

for arg in "$@"; do
    case "$arg" in
        --rebuild) REBUILD=1 ;;
        *) printf 'Unknown option: %s (supported: --rebuild)\n' "$arg" >&2; exit 2 ;;
    esac
done

for cmd in podman git nvidia-smi systemctl; do
    command -v "$cmd" >/dev/null 2>&1 || { printf 'Required command not found: %s\n' "$cmd" >&2; exit 1; }
done

[[ -f "$TYGER_REPO/Dockerfile" ]] || {
    printf 'tyger-s2s checkout not found at %s (set TYGER_REPO).\n' "$TYGER_REPO" >&2
    exit 1
}

SHA="$(git -C "$TYGER_REPO" rev-parse --short=7 HEAD)"
IMAGE="${IMAGE_REPO}:${SHA}"

if [[ "$REBUILD" == 1 ]] || ! podman image exists "$IMAGE"; then
    if [[ -n "$(git -C "$TYGER_REPO" status --porcelain)" ]]; then
        printf 'WARNING: %s has uncommitted changes; the image bakes the working tree.\n' "$TYGER_REPO" >&2
    fi
    printf 'Building %s from %s (this downloads nothing; the models live in the tyger-hf volume)...\n' "$IMAGE" "$TYGER_REPO"
    ( cd "$TYGER_REPO" && podman build -t "$IMAGE" . )
fi

# The unit must name the image that exists; the clone's commit is the tag.
if ! grep -q "^Image=${IMAGE_REPO}:${SHA}$" "$ROOT/quadlets/${UNIT}.container.in"; then
    printf 'NOTE: quadlets/%s.container.in does not name %s.\n' "$UNIT" "$IMAGE" >&2
    printf '      A rebuilt image with a new tag is not picked up until that line and the\n' >&2
    printf '      rendered unit are updated (the running container keeps its old image).\n' >&2
fi

"$ROOT/scripts/render-units.sh" "$UNIT"

if [[ ! -f "$ENV_FILE" ]]; then
    printf '\n%s is missing: the container needs HERMES_SHIM_KEY for the llm.smart\n' "$ENV_FILE" >&2
    printf 'plugin. Generate it with %s/make-shim-env.sh.\n' "${HOME}/.local/share/ai-lab/tyger" >&2
fi

printf '\nRendered %s from %s.\n' "$UNIT" "$IMAGE"
printf 'Start it with: ai-lab start tyger-s2s   (moves strata off the 5090; needs the 5090 free)\n'
