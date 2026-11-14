#!/usr/bin/env bash
# run-barge.sh <label> [gate:on|off] ["<first utterance>"] ["<second utterance>"]
#
# V03 step 4 acceptance: the scripted barge, gate OFF (PLAN-V03-step4-full-duplex.md §6.1).
# Beside gate1-turn.sh / gate1-mic-loopback.sh and gate2-fix/run-session.sh.
#
# One door session, no gateway restart:
#   link down -> gate <on|off> -> link up
#   -> play utt1 into MAX Out   (what a meeting app writes: the human)
#   -> wait until the reply is ARRIVING (maxaudiod.json rx_frames rising above a baseline)
#   -> play utt2 into MAX Out   (the peer talking over Max, mid-reply)
#   -> link down.
# The reply must stop mid-sentence: tyger `barge` (non-zero yield, heard_s > 0), the gateway
# logs the downlink stopped and `drain sent`, and maxaudiod.json play_samples stops rising.
#
# MAX Mic is NOT captured here: this shell holds no microphone TCC grant (`ffmpeg -f avfoundation`
# fails "Cannot use MAX Mic" and then HANGS). The barge needs only playback into MAX Out, which
# needs no grant. A real echo loop (MAX Mic -> MAX Out, the meeting-app stand-in) is an owner-shell
# action and is not part of this script.
#
# The audiotoolbox device index is looked up by UID at run time (MaxHole_2_UID = MAX Out), never
# hardcoded: the CoreAudio list changes when devices come and go, and a stale index fails with
# "AudioObjectGetPropertyData UID ..." and writes nothing at all.
#
# Reply-start detection keys off rx_frames, never play_samples: play_samples holds the PREVIOUS
# session's value until the new session's first playback, so "play_samples > 0" fires on a stale
# number and the barge lands before the reply starts (measured 2026-11-14, run 1 barged at 0.32 s).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FFMPEG="${FFMPEG:-/opt/homebrew/bin/ffmpeg}"
CF="$HOME/Library/Application Support/MaxPresence/cmd-maxaudiod.json"
J="$HOME/Library/Application Support/MaxPresence/maxaudiod.json"
LABEL="${1:?label}"
GATE="${2:-off}"
UTT1="${3:-Count slowly from one to twenty. Say each number on its own.}"
UTT2="${4:-Stop. Hold on, wait, I have a question for you.}"
REPLY_WAIT_S="${REPLY_WAIT_S:-30}"     # how long to wait for the reply to start arriving
BARGE_AFTER_S="${BARGE_AFTER_S:-1.2}"  # how far into the reply the peer speaks
VOICE="${VOICE:-Daniel}"

c() { python3 - "$1" <<'PY'
import json,sys
d=json.load(open(__import__("os").path.expanduser("~/Library/Application Support/MaxPresence/maxaudiod.json")))
keys=("connected","tx_frames","rx_frames","play_chunks","play_samples","gated_frames","tag_frames","played_reports","speaking_frames")
print(sys.argv[1], " ".join(f"{k}={d.get(k)}" for k in keys), "last_stat", d.get("last_stat"))
PY
}

# MAX Out's audiotoolbox index, by UID (mac/maxhole/src/maxhole.c: kDevice2 = MAX Out = MaxHole_2_UID)
AT="$("$FFMPEG" -hide_banner -f lavfi -i anullsrc=r=48000:cl=mono -t 0.1 -f audiotoolbox \
      -list_devices true -y /dev/null 2>&1)"
OUT_IDX="$(printf '%s\n' "$AT" | sed -nE 's/.*\] \[([0-9]+)\].*MaxHole_2_UID.*/\1/p' | head -1)"
if [ -z "$OUT_IDX" ]; then
    OUT_IDX="$("$SCRIPT_DIR/.venv/bin/python" - <<'PY'
import sounddevice as sd
print(next(i for i, d in enumerate(sd.query_devices()) if d["name"] == "MAX Out"))
PY
)"
    echo "run-barge: MaxHole_2_UID not in the audiotoolbox list; using device index $OUT_IDX (sounddevice order)"
else
    echo "run-barge: MAX Out = audiotoolbox [$OUT_IDX] (by MaxHole_2_UID)"
fi

# utterances as real 48k mono speech (say -> aiff -> wav)
U1="/tmp/barge-$LABEL-utt1.wav"; U2="/tmp/barge-$LABEL-utt2.wav"; A="/tmp/barge-$LABEL.aiff"
say -v "$VOICE" -o "$A" "$UTT1" && "$FFMPEG" -hide_banner -loglevel error -y -i "$A" -ar 48000 -ac 1 -c:a pcm_s16le "$U1"
say -v "$VOICE" -o "$A" "$UTT2" && "$FFMPEG" -hide_banner -loglevel error -y -i "$A" -ar 48000 -ac 1 -c:a pcm_s16le "$U2"

echo "run-barge: gate=$GATE label=$LABEL"
echo "  utt1: $UTT1"
echo "  utt2: $UTT2"

# Sample maxaudiod.json every 0.5 s for the whole run: shows the reply playing and then STOPPING
# (play_samples must plateau after the drain; acceptance §6.1).
SER="/tmp/barge-$LABEL-samples.csv"
: > "$SER"
( while :; do
    python3 -c "import json,os,time;d=json.load(open(os.path.expanduser('~/Library/Application Support/MaxPresence/maxaudiod.json')));print(f'{time.time():.1f},{d.get(\"rx_frames\")},{d.get(\"play_samples\")},{d.get(\"played_reports\")}')" >> "$SER" 2>/dev/null
    sleep 0.5
  done ) &
SAMPLER=$!
trap 'kill $SAMPLER 2>/dev/null' EXIT

printf '{"gate":%s,"link":"down"}\n' "$([ "$GATE" = on ] && echo true || echo false)" > "$CF"
sleep 3; c "BEFORE"
echo '{"gate":'$([ "$GATE" = on ] && echo true || echo false)',"link":"up"}' > "$CF"
sleep 12; c "OPEN"

# Baseline for the reply detector (see the header note on rx_frames vs play_samples).
rx0="$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/Library/Application Support/MaxPresence/maxaudiod.json'))).get('rx_frames',0))")"
echo "play utt1 at $(date +%T)"
"$FFMPEG" -hide_banner -loglevel error -re -i "$U1" -f audiotoolbox -audio_device_index "$OUT_IDX" -

# wait until the reply's audio is actually arriving (rx_frames rose above the baseline)
echo "waiting for the reply to arrive (up to ${REPLY_WAIT_S}s, rx baseline=$rx0)..."
t0=$(date +%s); started=0
while [ $(( $(date +%s) - t0 )) -lt "$REPLY_WAIT_S" ]; do
    rx="$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/Library/Application Support/MaxPresence/maxaudiod.json'))).get('rx_frames',0))")"
    if [ "${rx:-0}" -ge $(( rx0 + 8 )) ]; then started=1; echo "reply arriving (rx_frames=$rx) at $(date +%T)"; break; fi
    sleep 0.25
done
if [ "$started" = 0 ]; then echo "run-barge: NO reply arrived within ${REPLY_WAIT_S}s -- the barge was not attempted"; fi

sleep "$BARGE_AFTER_S"
echo "play utt2 (the peer) at $(date +%T)"
"$FFMPEG" -hide_banner -loglevel error -re -i "$U2" -f audiotoolbox -audio_device_index "$OUT_IDX" -

sleep 12; c "AFTER"
echo '{"link":"down"}' > "$CF"; sleep 3; c "CLOSED"
echo "run-barge: done at $(date +%T)"
