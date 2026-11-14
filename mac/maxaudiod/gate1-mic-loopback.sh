#!/usr/bin/env bash
# gate1-mic-loopback.sh -- does a KNOWN-LENGTH sound written into MAX Mic survive to MAX Mic's own
# input side, and for how long? The gateway is not involved at all.
#
#   gate1-mic-loopback.sh [OUT_DIR] [SECONDS]        (default 10 s of tone, 14 s capture)
#
# Why: a Gate 1 reply of 9.28 s reached plexpipe in full (its own stat counts the chunks, and the
# gateway's dumped Ogg decodes to 7.12 s of audio with ffmpeg), but the MAX Mic recording held only
# ~1.9 s before exact digital silence. That leaves two candidates and this separates them:
#
#   * if the recording holds ~the full tone  -> the MAX Mic path is fine, and the truncation is inside
#     maxaudiod's playback (its play loop / PortAudio stream), which is where to instrument next;
#   * if the recording holds only a second or two -> the truncation is in the MaxHole device pair or in
#     the capture, i.e. PRE-EXISTING and nothing to do with V03's gateway (personaplex would hit it too).
#
# MAX Mic is the "play in, meeting reads it as mic" device: audiotoolbox index for UID MaxHole_UID
# (kDevice = MAX Mic, mac/maxhole/src/maxhole.c:171,459; build.sh:25); avfoundation names it "MAX Mic".
#
# MUST RUN IN A SHELL HOLDING THE MICROPHONE TCC GRANT (Terminal).
set -uo pipefail

FFMPEG="${FFMPEG:-$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)}"
OUT_DIR="${1:-$HOME/Documents/Hermes/2026-11-13-voice-tooling-research/gate1}"
TONE_S="${2:-10}"
CAPTURE_S="${CAPTURE_S:-$((TONE_S + 4))}"

mkdir -p "$OUT_DIR" || exit 1
stamp="$(date +%Y%m%dT%H%M%S)"
rec="$OUT_DIR/mic-loopback-$stamp.wav"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

AV="$("$FFMPEG" -hide_banner -f avfoundation -list_devices true -i "" 2>&1)"
MIC_IDX="$(printf '%s\n' "$AV" | sed -nE 's/.*\] \[([0-9]+)\] MAX Mic.*/\1/p' | head -1)"
AT="$("$FFMPEG" -hide_banner -f lavfi -i anullsrc=r=48000:cl=mono -t 0.1 -f audiotoolbox \
      -list_devices true -y /dev/null 2>&1)"
MIC_OUT_IDX="$(printf '%s\n' "$AT" | sed -nE 's/.*\] \[([0-9]+)\].*MaxHole_UID.*/\1/p' | head -1)"
[ -n "$MIC_IDX" ] || { echo "mic-loopback: MAX Mic not in the avfoundation list"; exit 1; }
[ -n "$MIC_OUT_IDX" ] || { echo "mic-loopback: MaxHole_UID not in the audiotoolbox list"; exit 1; }
echo "mic-loopback: capture MAX Mic = avfoundation [$MIC_IDX]; play into MAX Mic = audiotoolbox [$MIC_OUT_IDX]"

# a 440 Hz tone: its length is unambiguous in the recording, unlike speech
"$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i "sine=frequency=440:sample_rate=24000:duration=$TONE_S" \
    -ac 1 -c:a pcm_s16le "$tmp/tone.wav" || exit 1
echo "mic-loopback: tone is $(ffprobe -v error -show_entries format=duration -of csv=p=0 "$tmp/tone.wav") s"

"$FFMPEG" -hide_banner -loglevel warning -f avfoundation -i ":$MIC_IDX" -t "$CAPTURE_S" \
    -ac 1 -ar 24000 -y "$rec" 2>"$tmp/cap.log" &
CAP=$!
sleep 2
echo "mic-loopback: playing the tone into MAX Mic at $(date +%T)"
"$FFMPEG" -hide_banner -loglevel error -re -i "$tmp/tone.wav" -f audiotoolbox -audio_device_index "$MIC_OUT_IDX" -
echo "mic-loopback: playback returned at $(date +%T)"
wait $CAP
[ -s "$rec" ] || { echo "mic-loopback: NO RECORDING -- capture log:"; cat "$tmp/cap.log"; exit 1; }

echo "--- per-second level of the recording (a 10 s tone should light up 10 rows) ---"
"$FFMPEG" -hide_banner -v error -i "$rec" -af "astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.RMS_level:file=-" \
    -f null - 2>/dev/null | grep -A1 'pts_time' | paste - - - 2>/dev/null | head -25
echo "--- whole-file stats ---"
"$FFMPEG" -hide_banner -i "$rec" -af volumedetect -f null - 2>&1 | grep -E 'mean_volume|max_volume'
echo "mic-loopback-artifact $rec (expect ~${TONE_S} s of tone, not 1-2 s)"