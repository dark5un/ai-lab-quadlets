#!/usr/bin/env bash
# turn-timeline.sh <label> [gate:on|off] ["<utterance>"] [outdir]
#
# The latency instrument of PLAN-latency.md: ONE scripted turn, one wall clock, five stamps.
#
#   t0  the harness stopped writing the utterance into MAX Out        (this Mac's clock, printed here)
#   t1  tyger's endpoint event        `endpoint by=head turn_s=...`   (tyger -t, box clock)
#   t2  tyger's first audio           `mouth: onset: ... first-audio` (tyger -t, box clock)
#   t3  the gateway's first frame of that reply out to the door       (gateway -t, box clock; the
#                                                                      `reply <rid>: first frame out`
#                                                                      line added for this instrument)
#   t4  the Mac's first playback of the reply  (maxaudiod `play-events.log`, this Mac's clock)
#
# Box stamps are moved onto this Mac's clock with the measured skew (the box runs ~0.2 s ahead of
# this Mac; the deltas that join the two machines are worth more than their skew, so it is measured
# and printed every run rather than assumed away).
#
# Why `play-events.log` and not `maxaudiod.json`: the status file is flushed every 2 s, so it cannot
# time a 1 s-scale event, and maxaudiod's own log is block-buffered through launchd, so its tail lags
# minutes. The play event is one flushed line per reply, stamped from the DAC clock, on this Mac.
#
# Direction reminder: maxaudiod CAPTURES MAX Out (what a meeting app writes = the human) and PLAYS
# INTO MAX Mic (what a meeting app reads = Max's voice). Playing into MAX Out needs no TCC grant, so
# this runs from an agent shell. Nothing here captures MAX Mic.
#
# Leaves the door link DOWN, as run-soak.sh and run-barge.sh do.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FFMPEG="${FFMPEG:-/opt/homebrew/bin/ffmpeg}"
FFPROBE="${FFPROBE:-/opt/homebrew/bin/ffprobe}"
CF="$HOME/Library/Application Support/MaxPresence/cmd-maxaudiod.json"
J="$HOME/Library/Application Support/MaxPresence/maxaudiod.json"
PLAY_EVENTS="$HOME/Library/Application Support/MaxPresence/play-events.log"
BOX="${BOX:-px@ai.tail1720c8.ts.net}"
LABEL="${1:?label}"
GATE="${2:-off}"
UTT="${3:-Count slowly from one to twenty. Say each number on its own.}"
OUTDIR="${4:-/tmp/timeline-$LABEL}"
VOICE="${VOICE:-Daniel}"
REPLY_WAIT_S="${REPLY_WAIT_S:-30}"
SESSION_WAIT_S="${SESSION_WAIT_S:-30}"
mkdir -p "$OUTDIR"

c() { python3 - "$1" <<'PY'
import json,os,sys
d=json.load(open(os.path.expanduser("~/Library/Application Support/MaxPresence/maxaudiod.json")))
keys=("connected","tx_frames","rx_frames","play_chunks","play_samples","tag_frames","played_reports")
print(sys.argv[1]," ".join(f"{k}={d.get(k)}" for k in keys),"last_stat",d.get("last_stat"))
PY
}

jget() { python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/Library/Application Support/MaxPresence/maxaudiod.json'))).get('$1'))"; }

# MAX Out's audiotoolbox index, by UID (mac/maxhole/src/maxhole.c: kDevice2 = MAX Out = MaxHole_2_UID)
AT="$("$FFMPEG" -hide_banner -f lavfi -i anullsrc=r=48000:cl=mono -t 0.1 -f audiotoolbox \
      -list_devices true -y /dev/null 2>&1)"
OUT_IDX="$(printf '%s\n' "$AT" | sed -nE 's/.*\] \[([0-9]+)\].*MaxHole_2_UID.*/\1/p' | head -1)"
if [ -z "$OUT_IDX" ]; then
    OUT_IDX="$(python3 -c 'import sounddevice as sd; print(next(i for i,d in enumerate(sd.query_devices()) if d["name"]=="MAX Out"))')"
    echo "turn-timeline: MaxHole_2_UID not in the audiotoolbox list; using index $OUT_IDX (sounddevice order)"
else
    echo "turn-timeline: MAX Out = audiotoolbox [$OUT_IDX] (by MaxHole_2_UID)"
fi

# the utterance, as real 48k mono speech
U="$OUTDIR/utt.wav"; A="$OUTDIR/utt.aiff"
say -v "$VOICE" -o "$A" "$UTT" && "$FFMPEG" -hide_banner -loglevel error -y -i "$A" -ar 48000 -ac 1 -c:a pcm_s16le "$U"
UTT_S="$("$FFPROBE" -v error -show_entries format=duration -of default=nw=1:nk=1 "$U")"
echo "turn-timeline: gate=$GATE label=$LABEL utterance=${UTT_S}s"
echo "  text: $UTT"
echo "$UTT_S" > "$OUTDIR/utt_s.txt"

# clock skew: box minus this Mac (5 samples, midpoint of the ssh round trip; the median is used)
SKEW="$(python3 - "$BOX" <<'PY'
import subprocess,sys,time
box=sys.argv[1]; est=[]
for _ in range(5):
    a=time.time()
    r=subprocess.run(["ssh",box,"date +%s.%N"],capture_output=True,text=True)
    b=time.time()
    est.append(float(r.stdout.strip())-(a+b)/2)
est.sort()
print(f"{est[len(est)//2]:.3f}")
PY
)"
echo "turn-timeline: clock skew box-mac = ${SKEW}s (box stamps are moved onto this Mac's clock)"
echo "$SKEW" > "$OUTDIR/skew.txt"

# baseline marks: the line count of the play events, and the counters
EV0=0; [ -f "$PLAY_EVENTS" ] && EV0="$(wc -l < "$PLAY_EVENTS" | tr -d ' ')"

printf '{"gate":%s,"link":"down"}\n' "$([ "$GATE" = on ] && echo true || echo false)" > "$CF"
sleep 3; c "BEFORE"
printf '{"gate":%s,"link":"up"}\n' "$([ "$GATE" = on ] && echo true || echo false)" > "$CF"

# wait for the door session itself (connected AND the heartbeat moving, never a stale field read)
t0s="$(date +%s)"; ok=0
while [ $(( $(date +%s) - t0s )) -lt "$SESSION_WAIT_S" ]; do
    if [ "$(jget connected)" = "True" ]; then ok=1; break; fi
    sleep 0.5
done
[ "$ok" = 1 ] || { echo "turn-timeline: NO door session after ${SESSION_WAIT_S}s -- link up failed; stopping"; printf '{"link":"down"}\n' > "$CF"; exit 1; }
sleep 5; c "OPEN"

# the turn
echo "play the utterance at $(date +%T)"
T_START="$(python3 -c 'import time;print(f"{time.time():.3f}")')"
"$FFMPEG" -hide_banner -loglevel error -re -i "$U" -f audiotoolbox -audio_device_index "$OUT_IDX" -
T0="$(python3 -c 'import time;print(f"{time.time():.3f}")')"
echo "$T0" > "$OUTDIR/t0.txt"
echo "t0 (utterance written, ${UTT_S}s of speech) = $T0"

# t4: the first `first-play rid>=1` line the daemon writes after this turn
t0s="$(date +%s)"; t4=""; rid=""
while [ $(( $(date +%s) - t0s )) -lt "$REPLY_WAIT_S" ]; do
    line="$(tail -n +$(( EV0 + 1 )) "$PLAY_EVENTS" 2>/dev/null | awk -v t="$T_START" '$1+0 >= t+0 && $3 !~ /rid=0$/ {print; exit}')"
    if [ -n "$line" ]; then t4="$(echo "$line" | awk '{print $1}')"; rid="$(echo "$line" | awk '{print $3}')"; break; fi
    sleep 0.2
done
if [ -z "$t4" ]; then echo "turn-timeline: NO playback seen within ${REPLY_WAIT_S}s (no reply, or no play event)"; else
    echo "t4 (first reply sample at MAX Mic's DAC) = $t4  ($rid)"; fi

sleep 4; c "AFTER"
printf '{"link":"down"}\n' > "$CF"; sleep 3; c "CLOSED"

# the box side, for the window around the turn
FROM="$(python3 -c "print(f'{float(open(\"$OUTDIR/t0.txt\").read().strip())-15:.3f}')")"
echo "pulling box logs since $FROM"
ssh "$BOX" "podman logs -t --since $FROM tyger-v1"            > "$OUTDIR/tyger.log"   2>&1
ssh "$BOX" "podman logs -t --since $FROM systemd-tyger-gateway" > "$OUTDIR/gateway.log" 2>&1
cp "$PLAY_EVENTS" "$OUTDIR/play-events.log" 2>/dev/null
wc -l "$OUTDIR/tyger.log" "$OUTDIR/gateway.log" | sed 's/^/  /'

python3 "$SCRIPT_DIR/turn-timeline.py" "$OUTDIR"
