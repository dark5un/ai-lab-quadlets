#!/usr/bin/env bash
# Per-card model links (scripts/llama-models.py) against a fake HF cache in
# the hf 2.x layout: snapshot symlink -> models--*/blobs symlink -> hub/blobs real file.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/llama-models-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export HF_HUB_CACHE="$TMP/hub" LLAMA_CARDS_DIR="$TMP/cards"
M() { python3 "$ROOT/scripts/llama-models.py" "$@"; }
fail() { echo "  FAIL: $*"; exit 1; }

# fake_file <repo> <relpath> <content>
fake_file() {
    local repo="$1" rel="$2" sha
    sha="$(printf '%s' "$3" | sha256sum | cut -c1-64)"
    local base="$HF_HUB_CACHE/models--${repo//\//--}"
    mkdir -p "$HF_HUB_CACHE/blobs/${sha:0:2}" "$base/blobs" "$base/refs" "$base/snapshots/rev1/$(dirname "$rel")"
    printf '%s' "$3" > "$HF_HUB_CACHE/blobs/${sha:0:2}/$sha"
    ln -sfn "../../blobs/${sha:0:2}/$sha" "$base/blobs/$sha"
    local up; up="$(dirname "$rel" | sed 's|[^/.][^/]*|..|g; s|^\.$||')"
    ln -sfn "${up:+$up/}../../blobs/$sha" "$base/snapshots/rev1/$rel"
    echo rev1 > "$base/refs/main"
}
fake_file org/Small-GGUF Small-Q4_K_M.gguf "small q4"
fake_file org/Small-GGUF Small-Q8_0.gguf "small q8"
fake_file org/Big-GGUF Q4_K_M/Big-Q4_K_M-00001-of-00002.gguf "big part 1"
fake_file org/Big-GGUF Q4_K_M/Big-Q4_K_M-00002-of-00002.gguf "big part 2"
fake_file org/Big-GGUF mmproj-Big-F16.gguf "projector"

# single file on two cards: one copy on disk
M link org/Small-GGUF '*Q4_K_M*.gguf' --card 5090,4070ti >/dev/null
f5="$LLAMA_CARDS_DIR/5090/Small-Q4_K_M/Small-Q4_K_M.gguf"
f4="$LLAMA_CARDS_DIR/4070ti/Small-Q4_K_M/Small-Q4_K_M.gguf"
[ -f "$f5" ] && [ ! -L "$f5" ] || fail "5090 link missing or a symlink"
[ "$(stat -c %i "$f5")" = "$(stat -c %i "$f4")" ] || fail "cards hold different copies"
[ "$(stat -c %h "$f5")" = 3 ] || fail "expected 3 links (store + 2 cards), got $(stat -c %h "$f5")"
[ ! -e "$LLAMA_CARDS_DIR/both/Small-Q4_K_M" ] || fail "linked onto an unrequested card"
[ ! -e "$LLAMA_CARDS_DIR/5090/Small-Q8_0" ] || fail "filter matched another quant"
# idempotent
M link org/Small-GGUF '*Q4_K_M*.gguf' --card 5090 >/dev/null || fail "re-link is not idempotent"

# split model in a repo subfolder: parts side by side in one model dir, plus the projector
M link org/Big-GGUF '*Q4_K_M*.gguf' --card both >/dev/null
d="$LLAMA_CARDS_DIR/both/Big-Q4_K_M"
[ -f "$d/Big-Q4_K_M-00001-of-00002.gguf" ] && [ -f "$d/Big-Q4_K_M-00002-of-00002.gguf" ] \
    || fail "split parts not side by side in $d"
ls "$LLAMA_CARDS_DIR/both" | grep -q -- '-of-' && fail "a split part became its own model"

# --name renames one model, refuses several
M link org/Small-GGUF 'Small-Q8_0.gguf' --card 4070ti --name small-q8 >/dev/null
[ -f "$LLAMA_CARDS_DIR/4070ti/small-q8/Small-Q8_0.gguf" ] || fail "--name not applied"
if M link org/Small-GGUF '*.gguf' --card 5090 --name x 2>/dev/null; then fail "--name accepted 2 models"; fi
if M link org/Small-GGUF '*.gguf' --card gpu0 2>/dev/null; then fail "unknown card accepted"; fi
if M link org/Missing-GGUF '*.gguf' --card 5090 2>/dev/null; then fail "uncached repo accepted"; fi

# unlink one card: the other card and the library keep the file
M unlink Small-Q4_K_M --card 4070ti >/dev/null
[ ! -e "$f4" ] || fail "unlink left the 4070ti link"
[ -f "$f5" ] && [ "$(stat -c %h "$f5")" = 2 ] || fail "unlink touched the 5090 link or the store"
if M unlink Small-Q4_K_M --card 4070ti 2>/dev/null; then fail "unlink of a missing model succeeded"; fi
if M unlink ../escape --card 5090 2>/dev/null; then fail "path traversal accepted"; fi

# list: library entries know their cards
M list --json | python3 -c '
import json, sys
inv = json.load(sys.stdin)
lib = {e["file"]: e["cards"] for e in inv["library"]}
assert lib["Small-Q4_K_M.gguf"] == ["5090"], lib
assert lib["Small-Q8_0.gguf"] == ["4070ti"], lib
assert lib["Q4_K_M/Big-Q4_K_M-00001-of-00002.gguf"] == ["both"], lib
assert [m["name"] for m in inv["cards"]["both"]] == ["Big-Q4_K_M"], inv["cards"]["both"]
' || fail "list --json"
echo "llama-models links passed."
