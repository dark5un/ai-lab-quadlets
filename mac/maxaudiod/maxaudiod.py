#!/usr/bin/env python3
"""maxaudiod — MaxPresence Mac audio bridge (P1 prototype).

Modes:
  loopback-test   verify MaxHole devices form two ISOLATED pipes (no server, no door)
  run --door URL  bridge MAX Out (capture) -> WSS 'A' uplink 48k s16le mono,
                  WSS downlink 'A' 24k s16le mono -> MAX Mic playback
                  protocol: docs/mac-virtual-devices-plan.md (JSON control + binary tag 'A'/'V')
  V03 step 4 (full duplex, I-26): every uplink block is followed by a 'P' tag
                  [rid][reply sample at 24k, -1 none][capture position at 48k], and a played-out
                  reply is reported as the text command played:<rid>:<samples>. The downlink gains
                  two JSON controls: {"t":"reply","rid":N} and {"t":"drain","rid":N}. The tag is
                  measured from PortAudio's device clock, not modelled (see PlayTrace).

Native rates dodge resampling: capture 48k, play downlink at 24k (MaxHole kSampleRates).
"""
import argparse, json, logging, math, os, queue, struct, sys, threading, time
from collections import deque

import numpy as np
import sounddevice as sd
import websocket  # websocket-client

MIC = "MAX Mic"     # our write target; meeting app reads its INPUT side
OUT = "MAX Out"     # our read target; meeting app writes to its OUTPUT side
CAP_RATE = 48000
PLAY_NATIVE = 24000  # downlink rate == MaxHole native; no resample needed
FRAME_MS = 20
GATE_HOLD = 1.2  # s — half-duplex loop-break (see Bridge.on_capture)
PLAY_SR = 24000  # downlink / MAX Mic rate: the playhead counts reply samples at this rate (I-26)
# The playhead tag on the door uplink (V03 step 4): reply id, the reply sample at PLAY_SR that was at
# the DAC when the block was captured (-1: nothing of a reply playing), and the capture position of
# that block at CAP_RATE. The position is what pairs the tag with its block after plexpipe's resample
# and Opus reframe; arrival order alone cannot (PLAN-V03-step4-full-duplex.md §4.2, §8).
TAG = struct.Struct("<iii")

log = logging.getLogger("maxaudiod")

# ---------------------------------------------------------------- status heartbeat
# Written every 2 s so the MAXBar menu-bar widget (and humans) can observe the
# door link without opening any audio stream. Consume freshness: ts older than
# ~3 intervals => daemon is gone. Schema is flat JSON; see mac/maxbar/.
STATUS_DIR = os.path.join(os.path.expanduser("~"), "Library", "Application Support", "MaxPresence")
STATUS_PATH = os.path.join(STATUS_DIR, "maxaudiod.json")
# The latency timeline's t4 (PLAN-latency.md): one flushed line per reply, written the moment the
# first sample of that reply reaches MAX Mic's DAC. The status file is no use for this (flushed
# every 2 s) and this file's line is useless for the log tail (launchd block-buffers stdout), so
# the instant gets its own append-only file, on the Mac's own clock. Read it with `tail`.
PLAY_EVENTS = os.path.join(STATUS_DIR, "play-events.log")


class Status:
    def __init__(self):
        self.lock = threading.Lock()
        self.data = {"pid": os.getpid(), "mode": None, "door": None,
                     "connected": False, "started": time.time(),
                     "last_connect": None, "last_stat": None,
                     "tx_frames": 0, "rx_frames": 0, "errors": 0,
                     "gated_frames": 0, "speaking_frames": 0,
                     "mailbox_frames": 0,
                     "play_chunks": 0, "play_samples": 0,
                     "tag_frames": 0, "played_reports": 0, "empty_downlinks": 0,
                     "plex_up": None, "bridge_up": None}

    def bump(self, **kw):
        with self.lock:
            self.data.update(kw)

    def inc(self, key):
        with self.lock:
            self.data[key] += 1

    def flush(self):
        with self.lock:
            snap = dict(self.data, ts=time.time())
        try:
            os.makedirs(STATUS_DIR, exist_ok=True)
            tmp = STATUS_PATH + ".tmp"
            with open(tmp, "w") as f:
                json.dump(snap, f)
            os.replace(tmp, STATUS_PATH)
        except OSError as e:
            log.warning("status write failed: %s", e)

    def heartbeat(self, stop):
        while not stop.wait(2):
            controls.poll()
            self.flush()


status = Status()

# ---------------------------------------------------------------- controls
# MAXBar (or a human) writes cmd-maxaudiod.json next to the heartbeat:
#   {"link":"up"|"down", "mute_mic":bool, "mute_uplink":bool, "gate":bool}
# polled every heartbeat tick; absent file = all permissive defaults.
# `gate` (V03 step 4 plan §4.1): the half-duplex flag as a RUNTIME field, so full duplex and the A/B
# fallback are one file edit. null/absent = keep the CLI default; launchd caches the CLI args, and
# changing them needs an owner bootout+bootstrap, which a test must not need.
CMD_PATH = os.path.join(STATUS_DIR, "cmd-maxaudiod.json")


class Controls:
    def __init__(self):
        self.link = "up"
        self.mute_mic = False
        self.mute_uplink = False
        self.gate = None          # None: follow --gate; True/False: override it
        self._mtime = None

    def poll(self):
        try:
            m = os.stat(CMD_PATH).st_mtime
        except OSError:
            if self._mtime is not None:
                log.info("cmd file gone - controls reset to defaults")
                self.__init__()
                status.bump(link_requested="up", mic_muted=False, uplink_muted=False, gate=None)
            return
        if m == self._mtime:
            return
        self._mtime = m
        try:
            with open(CMD_PATH) as f:
                j = json.load(f)
            self.link = "down" if j.get("link") == "down" else "up"
            self.mute_mic = bool(j.get("mute_mic"))
            self.mute_uplink = bool(j.get("mute_uplink"))
            self.gate = j.get("gate") if isinstance(j.get("gate"), bool) else None
            log.info("controls: link=%s mute_mic=%s mute_uplink=%s gate=%s",
                     self.link, self.mute_mic, self.mute_uplink, self.gate)
        except Exception as e:
            log.warning("cmd file unreadable: %s", e)
        status.bump(link_requested=self.link, mic_muted=self.mute_mic,
                    uplink_muted=self.mute_uplink, gate=self.gate)


controls = Controls()


def find_device(name, kind):
    for d in sd.query_devices():
        if name in d["name"]:
            ch = d["max_input_channels"] if kind == "input" else d["max_output_channels"]
            if ch:
                return d["index"]
    raise SystemExit(f"device {name!r} ({kind}) not found — install MaxHole and restart coreaudiod")


# ---------------------------------------------------------------- loopback test
def loopback_test():
    """Gate: each pipe loops to itself, and NOTHING crosses pipes (V-3)."""
    mic_idx, out_idx = find_device(MIC, "input"), find_device(OUT, "input")
    results = {}

    def rms(x):
        return float(np.sqrt(np.mean(x ** 2)))

    def energy_at(x, freq, rate):
        spec = np.abs(np.fft.rfft(x[:, 0] if x.ndim > 1 else x))
        fr = np.fft.rfftfreq(x.shape[0] if x.ndim < 2 else x.shape[0], 1 / rate)
        band = (fr > freq - 20) & (fr < freq + 20)
        return float(spec[band].max() / (spec.max() + 1e-12))

    pairs = [
        # (play_into, read_from, tone_freq, label)
        (MIC, MIC, 440.0, "MAX Mic loops to itself"),
        (MIC, OUT, 440.0, "MAX Mic does NOT leak to MAX Out"),
        (OUT, OUT, 880.0, "MAX Out loops to itself"),
        (OUT, MIC, 880.0, "MAX Out does NOT leak to MAX Mic"),
    ]
    for play_name, read_name, freq, label in pairs:
        rate = CAP_RATE
        play_idx = find_device(play_name, "output")
        read_idx = find_device(read_name, "input")
        expected = play_name == read_name
        # One DUPLEX stream: portaudio/AUHAL cannot open separate in/out
        # streams on the SAME device (-10863 "cannot do in current context").
        captured = []
        phase = [0.0]

        def cb(indata, outdata, frames, tsi, status):
            inc = 2 * math.pi * freq / rate
            sig = 0.25 * np.sin(phase[0] + inc * np.arange(frames))
            phase[0] = (phase[0] + inc * frames) % (2 * math.pi)
            outdata[:, :] = sig[:, None]
            captured.append(indata.copy())

        with sd.Stream(samplerate=rate, device=(read_idx, play_idx), channels=2,
                       blocksize=int(rate * 0.05), callback=cb):
            time.sleep(1.5)
        seg = np.vstack(captured)[int(0.5 * rate):]  # skip startup transient
        peak = energy_at(seg, freq, rate) if len(seg) > 1000 else 0.0
        ok = (peak > 0.3) if expected else (peak < 0.1 or rms(seg) < 1e-4)
        results[label] = (ok, peak, rms(seg))
        print(f"{'PASS' if ok else 'FAIL'}  {label}  (tone-peak={peak:.2f} rms={rms(seg):.5f})")

    fails = [k for k, (ok, *_r) in results.items() if not ok]
    print("\nloopback-test:", "ALL PASS" if not fails else f"FAILED: {fails}")
    return 0 if not fails else 1


# ---------------------------------------------------------------- the playhead (I-26)
class PlayTrace:
    """Where the reply is at the DAC, from PortAudio's own device clock.

    The output callback records, for every buffer it hands the device, the DAC time of the buffer's
    first frame and which reply sample that frame is. A captured MAX Out block then asks, for its own
    capture time, which reply sample was at the DAC then. Both device times are re-anchored to
    `time.perf_counter()` (each stream's own reference), so the two streams need not share a time base.
    """

    KEEP_S = 15.0   # windows older than this are dropped (a barge onset reaches back a few seconds)

    def __init__(self):
        self.lock = threading.Lock()
        self.windows = deque()          # (t0, t1, rid, first_sample) at PLAY_SR, oldest first
        self.last_rid = 0
        self.total = {}                 # rid -> reply samples handed to the device
        self.first_wall = {}            # rid -> wall clock of its first sample at the DAC (t4)

    def submit(self, t0, n, rid, first_sample):
        """`n` samples of reply `rid`, whose first sample is `first_sample`, reach the DAC from `t0`."""
        with self.lock:
            t1 = t0 + n / PLAY_SR
            if rid >= 0:
                if rid not in self.total:
                    # t4 of the latency timeline: `t0` is in perf_counter time (the device clock), so
                    # re-anchor this reply's first DAC instant onto the wall clock for a reader that
                    # has no access to our perf_counter. One time.time() call, no I/O in the callback.
                    self.first_wall[rid] = time.time() + (t0 - time.perf_counter())
                self.last_rid = rid
                self.total[rid] = first_sample + n
            self.windows.append((t0, t1, rid, first_sample))
            cut = t1 - self.KEEP_S
            while self.windows and self.windows[0][1] < cut:
                self.windows.popleft()

    def first_wall_events(self):
        """Take the reply-first-sample instants not yet written out (consumed, so each is written once)."""
        with self.lock:
            ev = self.first_wall
            self.first_wall = {}
            return ev

    def tag(self, t_capture):
        """(reply id, its sample at PLAY_SR at the DAC at t_capture); (last rid, -1) when idle."""
        with self.lock:
            for t0, t1, rid, first in reversed(self.windows):
                if t0 <= t_capture <= t1:
                    return rid, first + int((t_capture - t0) * PLAY_SR)
            return self.last_rid, -1

    def played_total(self, rid):
        """Reply samples of `rid` handed to the device so far (0 if none)."""
        with self.lock:
            return self.total.get(rid, 0)

    def clear(self):
        """A drain: playback is being flushed, so nothing scheduled is going to the DAC any more."""
        with self.lock:
            self.windows.clear()
            self.total.clear()
            self.first_wall.clear()


# ---------------------------------------------------------------- door bridge
class Bridge:
    def __init__(self, door, gate=False, mailbox=None):
        self.door = door
        self.gate = gate
        self.mailbox = mailbox
        if mailbox:
            os.makedirs(mailbox, exist_ok=True)
        self.last_downlink = 0.0
        self.tx = queue.Queue()
        self.ws = None
        self.stop = threading.Event()
        self.trace = PlayTrace()          # I-26: the playhead, from the DAC clock
        self.cur_rid = 0                  # the reply whose audio the downlink is carrying
        self.drain_pending = False        # a barge drain: flushed by the play callback, never here
        self.log_q = queue.Queue(maxsize=64)
        self._samples_logged = 0

    # -- websocket side
    def connect(self):
        self.ws = websocket.WebSocket()
        self.ws.connect(self.door, timeout=10)
        self.ws.send(json.dumps({"t": "hello", "v": 1, "caps": ["audio"]}))
        status.bump(connected=True, last_connect=time.time())
        log.info("door connected: %s", self.door)

    def reader(self):
        while not self.stop.is_set():
            try:
                msg = self.ws.recv()
            except Exception as e:
                status.bump(connected=False)
                status.inc("errors")
                log.warning("door recv error: %s", e)
                return
            if isinstance(msg, bytes):
                tag, payload = msg[:1], msg[1:]
                if tag == b"A":
                    status.inc("rx_frames")
                    pcm24 = np.frombuffer(payload, dtype="<i2").astype(np.float32) / 32768.0
                    if not pcm24.size:
                        # plexpipe can forward an EMPTY 'A' when sphn's decoder yields nothing for a
                        # message (0.1.12 needs a moment; measured 3 of 22 frames on 2026-11-14). An
                        # empty chunk must not enter the play queue: it would be taken for a reply
                        # sample boundary and report `played:1:0` before a single sample was played.
                        status.inc("empty_downlinks")
                        continue
                    # energy-aware gate: plexpipe pads the downlink with
                    # silent real-time frames — gate only on actual speech
                    if float(np.sqrt(np.mean(pcm24 ** 2))) > 0.01:
                        self.last_downlink = time.time()
                        status.inc("speaking_frames")
                    self.play_q.put((self.cur_rid, pcm24))
                elif tag == b"V":
                    if self.mailbox:
                        self.write_mailbox(payload)
            else:
                try:
                    ctrl = json.loads(msg)
                except json.JSONDecodeError:
                    continue
                if ctrl.get("t") == "stat":
                    # server "brain" flags pass through (contract: doc V stat;
                    # widget distinguishes link-up-but-server-down)
                    status.bump(last_stat=time.time(),
                                plex_up=ctrl.get("plex_up"), bridge_up=ctrl.get("bridge_up"),
                                server_up_frames=ctrl.get("up_frames"),
                                server_up_buffered=ctrl.get("up_buffered"),
                                server_down_frames=ctrl.get("down_frames"))
                elif ctrl.get("t") == "reply":
                    # A new reply's audio starts: name it, so the tag this Mac sends names the id the
                    # voice server knows (V03 step 4). Backchannels arrive as rid 0: played, never tagged.
                    rid = ctrl.get("rid")
                    if isinstance(rid, int):
                        if rid != self.cur_rid:
                            log.info("reply rid=%d begins", rid)
                        self.cur_rid = rid
                elif ctrl.get("t") == "drain":
                    # A barge: the gateway wants MAX Mic silent now. The flush itself belongs to the
                    # play callback (it owns the queue and the carry), so only ask here.
                    log.info("drain rid=%s from the gateway: flushing playback", ctrl.get("rid"))
                    self.drain_pending = True

    def write_mailbox(self, payload: bytes):
        """Atomic latest-frame handoff for the Camera Extension (P2)."""
        mailbox = self.mailbox
        if not mailbox:
            return
        tmp = os.path.join(mailbox, ".frame.tmp.jpg")
        with open(tmp, "wb") as f:
            f.write(payload)
        os.replace(tmp, os.path.join(mailbox, "frame.jpg"))
        status.inc("mailbox_frames")

    def _play_summary(self):
        log.info("playback session end: %d chunks, %.2f s handed to MAX Mic",
                 self.play_i, self.play_samples / PLAY_NATIVE)

    # -- audio side
    def run(self):
        self.play_q = queue.Queue(maxsize=50)
        # A new door session: the previous session's playhead trace is not this conversation's, and
        # its reply ids start again at 1 (so a stale `total` would suppress the new session's first
        # play stamp -- that is t4 of the latency timeline).
        self.trace.clear()
        # Frames left over from a previous door session (the send thread may have died mid-flight, and
        # the capture callback can still fire a few times while the streams close) must not go out on
        # the new socket: their capture positions belong to a stream that no longer exists.
        stale = 0
        while True:
            try:
                self.tx.get_nowait()
                stale += 1
            except queue.Empty:
                break
        if stale:
            log.info("dropped %d stale door frames from the previous session", stale)
        mic_idx = find_device(MIC, "output")
        out_idx = find_device(OUT, "input")
        cap_frames = int(CAP_RATE * FRAME_MS / 1000)
        out_frames = int(PLAY_NATIVE * FRAME_MS / 1000)
        trace = self.trace
        # Playback state, touched only by the output callback.
        carry = [np.zeros(0, np.float32)]
        rid = [0]
        submitted = [0]                  # reply samples handed to the DAC for the current reply
        pending: list = [None]           # (rid, samples, when the last of them reached the DAC)
        reported: list = [0, 0, 0.0]     # rid, samples and time of the last `played:` report
        cap_pos = [0]                    # samples captured on this stream (48 kHz): the tag's position
        level = [0.0]                    # the loudest uplink block this second (is the human arriving?)
        self.play_i = 0
        self.play_samples = 0
        self.play_write_s = 0.0

        def drain_now():
            """A barge: throw away everything not yet at the DAC. Safe only from the callback."""
            n = 0
            while True:
                try:
                    self.play_q.get_nowait()
                    n += 1
                except queue.Empty:
                    break
            carry[0] = np.zeros(0, np.float32)
            submitted[0] = 0
            pending[0] = None
            trace.clear()
            log.info("drain: %d queued chunks dropped, playback writes zeros from now", n)

        def on_play(outdata, frames, tsi, status_info):
            """Fill MAX Mic from the downlink queue; record where the reply is at the DAC (I-26).

            The device gives the DAC time of this buffer (`time.outputBufferDacTime`); it is re-anchored
            to `time.perf_counter()` so the input callback (a different stream) can compare. Each
            contiguous (reply id, reply sample) run that reaches the DAC this buffer goes to the trace.
            """
            if self.drain_pending:
                self.drain_pending = False
                drain_now()
            out = np.zeros(frames, np.float32)
            pos = 0
            segs = []
            while pos < frames:
                if carry[0].size == 0:
                    try:
                        new_rid, pcm = self.play_q.get_nowait()
                    except queue.Empty:
                        break
                    if new_rid != rid[0]:        # a new reply: its sample index starts at 0
                        rid[0] = new_rid
                        submitted[0] = 0
                    carry[0] = pcm
                take = min(frames - pos, carry[0].size)
                out[pos:pos + take] = carry[0][:take]
                segs.append((pos, rid[0], submitted[0], take))
                submitted[0] += take
                carry[0] = carry[0][take:]
                pos += take
            if controls.mute_mic:
                outdata[:, 0] = 0.0              # drained, not played: MAX Mic stays silent
                return
            outdata[:, 0] = out
            if segs:
                t0 = time.perf_counter() + (tsi.outputBufferDacTime - tsi.currentTime)
                last_end = t0
                for start, r, first, n in segs:
                    trace.submit(t0 + start / PLAY_NATIVE, n, r, first)
                    last_end = t0 + (start + n) / PLAY_NATIVE
                    self.play_i += 1
                    self.play_samples += n
                status.inc("play_chunks")
                status.bump(play_samples=int(self.play_samples))
                # A backchannel (rid 0) plays but is never tagged or reported (playback.py:30).
                pending[0] = (rid[0], submitted[0], last_end) if rid[0] else None
            elif carry[0].size == 0 and self.play_q.empty():
                # Idle with nothing queued: report how much of the reply has reached the DAC as
                # `played:<rid>:<samples>`. tyger keeps the highest report and ends the turn only when
                # it equals what it sent (app/ears/playback.py page_played/page_done), so a report
                # mid-reply is harmless and the LAST one is what ends the turn honestly instead of the
                # server's 2 s guess. One report per 250 ms at most, and only when the count grew.
                pr = pending[0]
                now = time.perf_counter()
                if pr is not None and pr[1] > 0 and pr[2] <= now:
                    if pr[0] != reported[0]:            # a new reply starts its own count
                        reported[0], reported[1] = pr[0], 0
                    if pr[1] > reported[1] and now - reported[2] >= 0.25:
                        reported[1], reported[2] = pr[1], now
                        self.tx.put(f"played:{pr[0]}:{pr[1]}")
                        status.inc("played_reports")
                        log.info("played:%d:%d (at the DAC, nothing queued)", pr[0], pr[1])

        def on_capture(indata, frames, tsi, status_info):
            # HALF-DUPLEX GATE (2026-11-12): Meet plays back Max's own voice through the speaker path
            # straight into MAX Out, so plexpipe hears Max and answers itself. While a downlink chunk is
            # recent, the uplink is silenced. Full duplex (I-26) replaces this with the playhead tag.
            status.inc("tx_frames")
            # I-26: what the user was hearing when this MAX Out block was captured, from the DAC clock
            t_adc = time.perf_counter() + (tsi.inputBufferAdcTime - tsi.currentTime)
            r, s = trace.tag(t_adc)
            at = cap_pos[0]
            cap_pos[0] += frames
            try:
                self.log_q.put_nowait((r, s))
            except queue.Full:
                pass
            gate = self.gate if controls.gate is None else controls.gate
            if controls.mute_uplink or (gate and time.time() - self.last_downlink < GATE_HOLD):
                status.inc("gated_frames")
                self.tx.put(b"A" + (b"\x00" * 2 * frames))
            else:
                mono = (indata[:, 0] + indata[:, 1]) * 0.5  # L+R downmix
                pcm = (np.clip(mono, -1, 1) * 32767).astype("<i2")  # s16le 48k mono
                self.tx.put(b"A" + pcm.tobytes())
                level[0] = max(level[0], float(np.sqrt(np.mean(np.square(mono)))))
            # The tag rides beside the block it describes, right after it on the same socket: reply id,
            # the reply sample at the DAC at this capture instant, and the capture position so the far
            # side can pair tag with block through plexpipe's resample and Opus reframe.
            self.tx.put(b"P" + TAG.pack(r, s, at))
            status.inc("tag_frames")

        rx_thread = threading.Thread(target=self.reader, daemon=True)
        tx_thread = threading.Thread(target=self._send_loop, daemon=True)
        with sd.InputStream(samplerate=CAP_RATE, device=out_idx, channels=2,
                            blocksize=cap_frames, callback=on_capture):
            with sd.OutputStream(samplerate=PLAY_NATIVE, device=mic_idx, channels=1,
                                 blocksize=out_frames, callback=on_play):
                rx_thread.start()
                tx_thread.start()
                try:
                    self._log_loop(level)
                finally:
                    self._play_summary()

    def _send_loop(self):
        """Send queued door frames ('A' uplink blocks, 'P' tags, `played:` reports) from a thread."""
        while not self.stop.is_set():
            try:
                msg = self.tx.get(timeout=0.05)
            except queue.Empty:
                continue
            ws = self.ws
            if ws is None:
                return
            try:
                if isinstance(msg, str):
                    ws.send(msg, opcode=websocket.ABNF.OPCODE_TEXT)   # played:<rid>:<samples>
                else:
                    ws.send(msg, opcode=websocket.ABNF.OPCODE_BINARY)
            except Exception as e:
                status.bump(connected=False)
                status.inc("errors")
                log.warning("door send failed: %s", e)
                return

    def _write_play_events(self):
        """Append one flushed line per reply whose first sample just reached the DAC (t4 of the
        latency timeline). Written here, off the audio callback, so the callback does no I/O."""
        for rid, wall in self.trace.first_wall_events().items():
            try:
                with open(PLAY_EVENTS, "a") as f:
                    f.write(f"{wall:.3f} first-play rid={rid}\n")
            except OSError as e:
                log.warning("play event write failed: %s", e)

    def _log_loop(self, level=None):
        """Log the DAC playhead once a second (and the loudest uplink block: is the human arriving?)."""
        while not self.stop.is_set() and controls.link != "down":
            self._write_play_events()
            try:
                r, s = self.log_q.get(timeout=0.2)
            except queue.Empty:
                continue
            self._samples_logged += 1
            if self._samples_logged % 50 == 0:      # ~1 s of 20 ms blocks
                rms = 0.0
                if level is not None:
                    rms, level[0] = level[0], 0.0
                log.info("playhead: rid=%d sample=%d (queue %d, uplink rms %.3f)",
                         r, s, self.play_q.qsize(), rms)
        log.info("link down requested - dropping door socket")
        if self.ws is not None:
            try:
                self.ws.close()
            except Exception:
                pass

    def loop(self):
        backoff = 1
        while not self.stop.is_set():
            controls.poll()
            if controls.link == "down":
                status.bump(connected=False)
                self.stop.wait(1)
                continue
            try:
                self.connect()
                self.run()
                backoff = 1
            except Exception as e:
                status.bump(connected=False)
                status.inc("errors")
                log.warning("bridge down: %s (retry in %ss)", e, backoff)
                self.stop.wait(backoff)
                backoff = min(backoff * 2, 30)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["loopback-test", "run"])
    ap.add_argument("--door", help="wss:// URL from the doc (P0 assigns it)")
    ap.add_argument("--gate", action="store_true",
                    help="half-duplex uplink gate; ONLY for the single-session "
                         "design where Max owns the human's mic slot. In the "
                         "two-session model (Max joins as his own participant) "
                         "Meet never feeds Max his own voice, so the gate is "
                         "unneeded and would kill barge-in.")
    ap.add_argument("--mailbox", default=None,
                    help="P2: dir (App Group container/mailbox) where JPEG 'V' "
                         "frames are written atomically as frame.jpg for the "
                         "MAX Camera extension; unset = drop V frames (P1 behaviour)")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(name)s %(levelname)s %(message)s")
    # normalize door BEFORE first heartbeat so status shows what is actually used
    if args.door:
        # PITFALL 2026-11-12 (root-caused with byte-level ClientHello replay):
        # tailscale status JSON DNSName ends with a trailing dot
        # ("ai.<tailnet>.ts.net."). That dot becomes a trailing-dot SNI which
        # tailscale serve's Go TLS rejects with TLSV1_ALERT_DECODE_ERROR
        # (curl/SecureTransport normalize it; python/OpenSSL do not).
        from urllib.parse import urlsplit, urlunsplit
        parts = urlsplit(args.door)
        if (parts.hostname or "").endswith("."):
            netloc = parts.hostname[:-1] + (f":{parts.port}" if parts.port else "")
            args.door = urlunsplit((parts.scheme, netloc, parts.path, parts.query, parts.fragment))
    status.bump(mode=args.mode, door=args.door)
    stop = threading.Event()
    threading.Thread(target=status.heartbeat, args=(stop,), daemon=True).start()
    status.flush()
    try:
        if args.mode == "loopback-test":
            sys.exit(loopback_test())
        if not args.door:
            raise SystemExit("run mode needs --door (see docs/mac-virtual-devices-plan.md; P0 door URL lands in the doc)")
        Bridge(args.door, gate=args.gate, mailbox=args.mailbox).loop()
    finally:
        stop.set()
        status.bump(connected=False)
        status.flush()


if __name__ == "__main__":
    main()
