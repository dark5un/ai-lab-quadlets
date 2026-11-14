#!/usr/bin/env bash
# gate1-turn.sh -- one Gate 1 turn through the real door, recorded off MAX Mic.
#
#   gate1-turn.sh [OUT_DIR] ["utterance text"]
#
# Gate 1 (PLAN-V03-step2.md §2) puts a real utterance into the chain and records what comes back:
#
#   say (system TTS) -> ffmpeg audiotoolbox -> MAX Out   (what a meeting app writes: the human)
#   MAX Out -> maxaudiod --gate -> :8457 -> plexpipe -> tyger-gateway -> tyger /ws  (real, unchanged)
#   MAX Mic <- maxaudiod <- plexpipe <- tyger-gateway <- tyger                       (Max's voice back)
#   ffmpeg avfoundation off MAX Mic -> the recording (the "a human would hear it" proxy)
#
# Nothing here stands in for a protocol peer: say/ffmpeg are system tools writing into a HAL device,
# which is byte-for-byte what a meeting app does.
#
# MUST RUN IN A SHELL THAT HOLDS THE MICROPHONE TCC GRANT (Terminal, or the owner's shell):
# a process without it fails with "Failed to create AV capture input device: Cannot use MAX Mic".
#
# Both device indices are looked up by NAME, never assumed: audiotoolbox does not name its devices
# (they print as "(null)"), so it is matched on the MaxHole UID -- the driver's kDevice2 = MAX Out
# with UID MaxHole_2_UID (mac/maxhole/src/maxhole.c:172,188; build.sh:26), kDevice = MAX Mic = MaxHole_UID.
set -uo pipefail

FFMPEG="${FFMPEG:-$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)}"
OUT_DIR="${1:-$HOME/Documents/Hermes/2026-11-13-voice-tooling-research/gate1}"
UTTER="${2:-Max, what is the first thing I should do in the morning?}"
VOICE="${VOICE:-Daniel}"          # a British-ish say voice; the content matters, not the timbre
CAPTURE_S="${CAPTURE_S:-45}"      # must cover: 4 s lead-in + the utterance + the reply + margin
LEAD_IN_S="${LEAD_IN_S:-4}"
MODEL="${MODEL:-$HOME/.local/share/whisper-cpp/ggml-base.en.bin}"

mkdir -p "$OUT_DIR" || exit 1
stamp="$(date +%Y%m%dT%H%M%S)"
rec="$OUT_DIR/turn-$stamp.wav"
utt="$OUT_DIR/utterance-$stamp.wav"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- device indices, by name -------------------------------------------------------------------
AV="$("$FFMPEG" -hide_banner -f avfoundation -list_devices true -i "" 2>&1)"
MIC_IDX="$(printf '%s\n' "$AV" | sed -nE 's/.*\] \[([0-9]+)\] MAX Mic.*/\1/p' | head -1)"
AT="$("$FFMPEG" -hide_banner -f lavfi -i anullsrc=r=48000:cl=mono -t 0.1 -f audiotoolbox \
      -list_devices true -y /dev/null 2>&1)"
OUT_IDX="$(printf '%s\n' "$AT" | sed -nE 's/.*\] \[([0-9]+)\].*MaxHole_2_UID.*/\1/p' | head -1)"
[ -n "$MIC_IDX" ] || { echo "gate1-turn: MAX Mic not in the avfoundation device list"; exit 1; }
[ -n "$OUT_IDX" ] || { echo "gate1-turn: MaxHole_2_UID (MAX Out) not in the audiotoolbox device list"; exit 1; }
echo "gate1-turn: MAX Mic = avfoundation [$MIC_IDX], MAX Out = audiotoolbox [$OUT_IDX]"

# --- the utterance, as real speech -------------------------------------------------------------
say -v "$VOICE" -o "$tmp/utt.aiff" "$UTTER" || exit 1
"$FFMPEG" -hide_banner -loglevel error -y -i "$tmp/utt.aiff" -ar 48000 -ac 1 -c:a pcm_s16le "$utt" || exit 1
echo "gate1-turn: utterance $(ffprobe -v error -show_entries format=duration -of csv=p=0 "$utt") s: $UTTER"

# --- capture MAX Mic while the utterance is played into MAX Out --------------------------------
"$FFMPEG" -hide_banner -loglevel warning -f avfoundation -i ":$MIC_IDX" -t "$CAPTURE_S" \
    -ac 1 -ar 48000 -y "$rec" 2>"$tmp/cap.log" &
CAP=$!
sleep "$LEAD_IN_S"
echo "gate1-turn: playing into MAX Out at $(date +%T)"
"$FFMPEG" -hide_banner -loglevel error -re -i "$utt" -f audiotoolbox -audio_device_index "$OUT_IDX" -
wait $CAP
echo "gate1-turn: capture finished at $(date +%T); $rec"

if [ ! -s "$rec" ]; then
    echo "gate1-turn: NO RECORDING -- capture log:"; cat "$tmp/cap.log"; exit 1
fi

# --- was there speech in it, and what did it say ----------------------------------------------
echo "--- duration ---"; ffprobe -v error -show_entries format=duration -of csv=p=0 "$rec"
echo "--- level ---"
"$FFMPEG" -hide_banner -i "$rec" -af volumedetect -f null - 2>&1 | grep -E 'mean_volume|max_volume'
echo "--- non-silent spans (noise -45 dB, min 0.5 s) ---"
"$FFMPEG" -hide_banner -i "$rec" -af silencedetect=noise=-45dB:d=0.5 -f null - 2>&1 \
    | grep -E 'silence_end' | head -20

if [ -f "$MODEL" ]; then
    echo "--- transcript (whisper.cpp, $(basename "$MODEL")) ---"
    whisper-cli -m "$MODEL" -f "$rec" -nt -np 2>/dev/null | sed '/^$/d'
else
    echo "--- no whisper model at $MODEL: transcript skipped (level + spans only) ---"
fi

echo "GATE1-ARTIFACTS $rec $utt"