#!/usr/bin/env bash
# run-soak.sh [MINUTES] [gate:on|off]
#
# The V05 soak (issue 05's acceptance): one door session held open for MINUTES (default 30) while a
# scripted meeting happens on it, no owner present. Turns alternate short and long, and every other
# turn the "peer" talks over Max mid-reply, so barges, drains and playhead tags are all exercised
# hundreds of times.
#
#   link down -> gate <on|off> -> link up -> turns ... -> link down
#
# Metrics it can collect on its own, into /tmp/soak-<stamp>-samples.csv: rx_frames (the downlink the
# door delivered), play_samples (what reached MAX Mic), played_reports (the Mac's measured playhead
# reports), errors. It prints the container-log greps for the rest (echo dB, barged, latency, storms),
# which are the real acceptance numbers.
#
# MAX Mic is NOT captured (this shell holds no microphone TCC grant): the soak measures the chain, not
# what a human would hear. What a human hears was judged in Gate 2 and step 6.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FFMPEG="${FFMPEG:-/opt/homebrew/bin/ffmpeg}"
CF="$HOME/Library/Application Support/MaxPresence/cmd-maxaudiod.json"
J="$HOME/Library/Application Support/MaxPresence/maxaudiod.json"
MINUTES="${1:-30}"
GATE="${2:-off}"
STAMP="$(date +%Y%m%dT%H%M%S)"
SER="/tmp/soak-$STAMP-samples.csv"
TURNS_LOG="/tmp/soak-$STAMP-turns.log"
VOICE="${VOICE:-Daniel}"
REPLY_WAIT_S="${REPLY_WAIT_S:-30}"
BARGE_AFTER_S="${BARGE_AFTER_S:-2.0}"
SETTLE_S="${SETTLE_S:-10}"

c() { python3 - "$1" <<'PY'
import json,sys
d=json.load(open(__import__("os").path.expanduser("~/Library/Application Support/MaxPresence/maxaudiod.json")))
keys=("connected","tx_frames","rx_frames","play_chunks","play_samples","gated_frames","tag_frames","played_reports","speaking_frames","errors")
print(sys.argv[1], " ".join(f"{k}={d.get(k)}" for k in keys))
PY
}

jq_field() { python3 -c "import json,os,sys;print(json.load(open(os.path.expanduser('~/Library/Application Support/MaxPresence/maxaudiod.json'))).get(sys.argv[1],0))" "$1"; }

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
    echo "run-soak: MaxHole_2_UID not in the audiotoolbox list; using device index $OUT_IDX (sounddevice order)"
else
    echo "run-soak: MAX Out = audiotoolbox [$OUT_IDX] (by MaxHole_2_UID)"
fi

# A small pool of utterances: short ones end the turn quickly, the long one gives the peer something
# to interrupt. Written as real 48k mono speech, exactly what a meeting app puts into MAX Out.
UTTS=(
  "Hello. What is the weather like in London today?"
  "Tell me something interesting about the sea, in a couple of sentences. Take a moment to think about it before you answer."
  "What is two plus two?"
  "Explain, step by step and in detail, how a radio receiver picks one station out of all the signals in the air."
  "Thank you. Can you be a little more specific about that?"
  "Say a few words about why the sky is blue."
)
BARGE_UTT="Hold on, stop there, I want to ask you something else."
NPOOL=${#UTTS[@]}
for i in "${!UTTS[@]}"; do
    A="/tmp/soak-utt$i.aiff"
    say -v "$VOICE" -o "$A" "${UTTS[$i]}" && "$FFMPEG" -hide_banner -loglevel error -y -i "$A" \
        -ar 48000 -ac 1 -c:a pcm_s16le "/tmp/soak-utt$i.wav"
done
say -v "$VOICE" -o /tmp/soak-barge.aiff "$BARGE_UTT" && "$FFMPEG" -hide_banner -loglevel error -y \
    -i /tmp/soak-barge.aiff -ar 48000 -ac 1 -c:a pcm_s16le /tmp/soak-barge.wav

echo "run-soak: $MINUTES min, gate=$GATE, samples=$SER, turns=$TURNS_LOG"

# Sample the status file every 5 s for the whole soak.
: > "$SER"
( while :; do
    python3 -c "import json,os,time;d=json.load(open(os.path.expanduser('~/Library/Application Support/MaxPresence/maxaudiod.json')));print(f'{time.time():.1f},{d.get(\"rx_frames\")},{d.get(\"play_samples\")},{d.get(\"played_reports\")},{d.get(\"errors\")},{d.get(\"connected\")}')" >> "$SER" 2>/dev/null
    sleep 5
  done ) &
SAMPLER=$!
trap 'kill $SAMPLER 2>/dev/null' EXIT

printf '{"gate":%s,"link":"down"}\n' "$([ "$GATE" = on ] && echo true || echo false)" > "$CF"
sleep 3; c "BEFORE"
printf '{"gate":%s,"link":"up"}\n' "$([ "$GATE" = on ] && echo true || echo false)" > "$CF"
sleep 12; c "OPEN"
: > "$TURNS_LOG"

DEADLINE=$(( $(date +%s) + MINUTES * 60 ))
turn=0; replies=0; no_reply=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    turn=$((turn + 1))
    u=$(($(($turn - 1)) % NPOOL))
    rx0="$(jq_field rx_frames)"
    echo "$(date +%T) turn $turn: playing utterance $u" | tee -a "$TURNS_LOG"
    "$FFMPEG" -hide_banner -loglevel error -re -i "/tmp/soak-utt$u.wav" -f audiotoolbox -audio_device_index "$OUT_IDX" -

    t0=$(date +%s); started=0
    while [ $(( $(date +%s) - t0 )) -lt "$REPLY_WAIT_S" ]; do
        rx="$(jq_field rx_frames)"
        if [ "${rx:-0}" -ge $(( rx0 + 8 )) ]; then
            started=1; replies=$((replies + 1))
            echo "$(date +%T) turn $turn: reply arrived after $(( $(date +%s) - t0 ))s (rx_frames $rx0 -> $rx)" | tee -a "$TURNS_LOG"
            break
        fi
        sleep 0.25
    done
    if [ "$started" = 0 ]; then
        no_reply=$((no_reply + 1))
        echo "$(date +%T) turn $turn: NO reply within ${REPLY_WAIT_S}s" | tee -a "$TURNS_LOG"
    fi

    if [ $((turn % 2)) -eq 0 ] && [ "$started" = 1 ]; then       # every other turn: the peer interrupts
        sleep "$BARGE_AFTER_S"
        echo "$(date +%T) turn $turn: peer speaks over Max" | tee -a "$TURNS_LOG"
        "$FFMPEG" -hide_banner -loglevel error -re -i /tmp/soak-barge.wav -f audiotoolbox -audio_device_index "$OUT_IDX" -
    fi
    sleep "$SETTLE_S"
done

kill "$SAMPLER" 2>/dev/null
echo "$(date +%T) soak done: $turn turns, $replies with a reply, $no_reply without" | tee -a "$TURNS_LOG"
c "AFTER"
printf '{"link":"down"}\n' > "$CF"
sleep 3; c "CLOSED"
cat <<EOF

run-soak: done. Local numbers are in $SER and $TURNS_LOG.
The acceptance numbers are in the container logs (gate=$GATE, one session, no restart):

  # ai box
  podman logs --tail 200000 -t tyger-v1 | grep -cE 'turn_done barged=True'
  podman logs --tail 200000 -t tyger-v1 | grep -E 'echo ' | awk '{...}'   # echo dB range per turn
  podman logs --tail 200000 -t tyger-v1 | grep -c 'endpoint by='
  podman logs --tail 200000 -t systemd-tyger-gateway | grep -cE 'barge yield'
  podman logs --tail 200000 -t systemd-tyger-gateway | grep -c 'drain sent'
  podman logs --tail 200000 -t systemd-tyger-gateway | grep -c 'plex session closed'
  podman logs --tail 200000 -t systemd-plexpipe | grep -c 'ended (sending on a closed channel)'

To put the link back up: '{"gate":false,"link":"up"}' in cmd-maxaudiod.json.
EOF
