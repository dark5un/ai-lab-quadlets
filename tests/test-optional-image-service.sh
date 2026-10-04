#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/optional-image-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/podman" <<'STUB'
#!/usr/bin/env bash
[[ "${MOCK_IMAGE_PRESENT:-0}" == 1 ]]
STUB
cat > "$TMP/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$MOCK_LOG"
STUB
chmod +x "$TMP/bin/podman" "$TMP/bin/systemctl"
PATH="$TMP/bin:/usr/bin:/bin"
export PATH MOCK_LOG="$TMP/calls.log"

source "$ROOT/scripts/optional-image-service.sh"
restart_service() { printf 'restart %s\n' "$1" >> "$MOCK_LOG"; }

start_optional_image_service hyperframes localhost/hyperframes:latest
grep -q '^systemctl --user disable --now hyperframes.service$' "$MOCK_LOG"
if grep -q '^restart hyperframes$' "$MOCK_LOG"; then
  echo 'service restarted even though image is missing' >&2
  exit 1
fi

: > "$MOCK_LOG"
MOCK_IMAGE_PRESENT=1 start_optional_image_service hyperframes localhost/hyperframes:latest
grep -q '^restart hyperframes$' "$MOCK_LOG"
if grep -q 'disable --now hyperframes.service' "$MOCK_LOG"; then
  echo 'service was disabled even though image exists' >&2
  exit 1
fi
printf '%s\n' 'Optional image service guard passed.'
