"""Does the session recorder (V05.4) write both legs, at the right rate, with the right length?

Run inside the gateway container (tests/test-tyger-gateway-recording.sh does that). It imports the
gateway's own server module and drives SessionRecorder directly, then reads the files back with the
stdlib: a wrong rate or a dropped tail would make the owner's replay sound wrong while the live call
was fine, which is exactly the kind of defect a live test cannot see.
"""
import os
import sys
import tempfile
import wave

import numpy as np

sys.path.insert(0, os.environ.get("GATEWAY_APP", "/app"))
import server  # noqa: E402

UP_BLOCKS, BLK = 50, server.BLOCK              # 50 x 20 ms = 1.0 s at 16 kHz
DOWN_CHUNKS, CHUNK = 3, 1920                   # 3 x 80 ms = 0.24 s at 24 kHz
UP_AMP, DOWN_AMP = 0.25, 0.5

fail = 0


def check(cond, msg):
    global fail
    if not cond:
        fail = 1
        print(f"  FAIL: {msg}")


root = tempfile.mkdtemp(prefix="rec-check-")
rec = server.SessionRecorder(root, "recording check")
up = np.full(BLK, UP_AMP, np.float32)
for _ in range(UP_BLOCKS):
    rec.uplink_block(up, 16000)
down = np.full(CHUNK, DOWN_AMP, np.float32)
for rid in (1, 1, 2):
    rec.downlink_audio(rid, down)
path = rec.close("check session summary line")

for leg, want_sr, want_frames, want_amp in (("uplink.wav", 16000, UP_BLOCKS * BLK, UP_AMP),
                                           ("downlink.wav", 24000, DOWN_CHUNKS * CHUNK, DOWN_AMP)):
    p = os.path.join(path, leg)
    check(os.path.isfile(p), f"{leg} missing")
    if not os.path.isfile(p):
        continue
    with wave.open(p) as w:
        check(w.getnchannels() == 1, f"{leg}: channels={w.getnchannels()}, want 1")
        check(w.getsampwidth() == 2, f"{leg}: width={w.getsampwidth()}, want 2")
        check(w.getframerate() == want_sr, f"{leg}: rate={w.getframerate()}, want {want_sr}")
        check(w.getnframes() == want_frames, f"{leg}: frames={w.getnframes()}, want {want_frames}")
        data = np.frombuffer(w.readframes(w.getnframes()), "<i2")
    peak = int(np.abs(data).max()) if data.size else 0
    want_peak = round(want_amp * 32767)
    check(abs(peak - want_peak) <= 1, f"{leg}: peak={peak}, want {want_peak}")

txt = open(os.path.join(path, "session.txt")).read() if os.path.isfile(
    os.path.join(path, "session.txt")) else ""
check("replies: [1, 2]" in txt, f"session.txt does not list both replies: {txt!r}")
check("check session summary line" in txt, "session.txt does not carry the summary line")
check("uplink.wav   1.0 s" in txt, f"session.txt uplink length wrong: {txt!r}")
check("downlink.wav 0.2 s" in txt, f"session.txt downlink length wrong: {txt!r}")

# The recorder must be inert when the feature is off: RECORD_DIR unset means no object, and the
# callers guard on it (server.SessionRecorder is never constructed).
check(server.RECORD_DIR in (None, ""), f"RECORD_DIR not empty in this container: {server.RECORD_DIR!r}")

print(f"recording check: {'FAILED' if fail else 'passed'} ({path})")
sys.exit(fail)
