#!/usr/bin/env bash
# Dictation accel switch: `ai-lab dictation` must
#   - report gpu|cpu (status form) and accept gpu|cpu (set form),
#   - write the drop-in at ~/.config/systemd/user/voxtype.service.d/
#     ryoku-ai-lab-accel.conf with a cleared + re-set ExecStart pointing at
#     the right /usr/lib/voxtype variant binary,
#   - never touch the shipped unit or /usr/bin/voxtype (no root),
#   - re-apply whisper.gpu_device=2 on the gpu pick (Hub > Dictation wipes it),
#   - and the plugin manifest must declare the same verbs the panel calls.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AI_LAB="$ROOT/scripts/ai-lab"
DROPIN="$HOME/.config/systemd/user/voxtype.service.d/ryoku-ai-lab-accel.conf"
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$AI_LAB" ] || fail "scripts/ai-lab not executable"

# status form works and answers gpu|cpu
case "$("$AI_LAB" dictation)" in gpu|cpu) ;; *) fail "dictation status must print gpu|cpu";; esac

# set form: write to a scratch copy of the logic (do NOT restart the live
# daemon in tests) — exercise the drop-in rendering by sourcing the function.
tmp=$(mktemp -d)
HOME_BAK="$HOME"
export HOME="$tmp"
DROPIN_TMP="$tmp/.config/systemd/user/voxtype.service.d/ryoku-ai-lab-accel.conf"
mkdir -p "$tmp/.config/systemd/user/voxtype.service.d"
# stub the side effects the set path runs
mkdir -p "$tmp/bin"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/systemctl"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/voxtype"
chmod +x "$tmp/bin/systemctl" "$tmp/bin/voxtype"
export PATH="$tmp/bin:$PATH"
"$AI_LAB" dictation gpu || fail "dictation gpu (stubbed) failed"
grep -q 'voxtype-vulkan' "$DROPIN_TMP" || fail "gpu pick must point at voxtype-vulkan"
grep -q '^ExecStart=$' "$DROPIN_TMP" || fail "the drop-in must clear ExecStart before re-setting it"
"$AI_LAB" dictation cpu || fail "dictation cpu (stubbed) failed"
grep -q 'voxtype-avx2' "$DROPIN_TMP" || fail "cpu pick must point at voxtype-avx2"
case "$("$AI_LAB" dictation)" in cpu) ;; *) fail "status must read back the drop-in";; esac
export HOME="$HOME_BAK"
rm -rf "$tmp"

# the shipped unit must not be edited by us
grep -q 'ExecStart=/usr/bin/voxtype daemon' "$HOME/.config/systemd/user/voxtype.service" \
    || fail "shipped voxtype.service changed unexpectedly"

# plugin: the panel calls switchDictation; the service exposes it + polls it
grep -q 'switchDictation' "$ROOT/plugin/ailab/content/Panel.qml" || fail "panel missing switchDictation"
grep -q 'function switchDictation' "$ROOT/plugin/ailab/service/Main.qml" || fail "service missing switchDictation"
grep -q '"dictation"' "$ROOT/plugin/ailab/service/Main.qml" || fail "service must call the dictation verb"

echo "PASS: dictation accel switch (drop-in, verbs, plugin wiring)"
