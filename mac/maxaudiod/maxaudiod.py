#!/usr/bin/env python3
"""maxaudiod — MaxPresence Mac audio bridge (P1 prototype).

Modes:
  loopback-test   verify MaxHole devices form two ISOLATED pipes (no server, no door)
  run --door URL  bridge MAX Out (capture) -> WSS 'A' uplink 48k s16le mono,
                  WSS downlink 'A' 24k s16le mono -> MAX Mic playback
                  protocol: docs/mac-virtual-devices-plan.md (JSON control + binary tag 'A'/'V')

Native rates dodge resampling: capture 48k, play downlink at 24k (MaxHole kSampleRates).
"""
import argparse, json, logging, math, os, queue, sys, threading, time
import numpy as np
import sounddevice as sd
import websocket  # websocket-client

MIC = "MAX Mic"     # our write target; meeting app reads its INPUT side
OUT = "MAX Out"     # our read target; meeting app writes to its OUTPUT side
CAP_RATE = 48000
PLAY_NATIVE = 24000  # downlink rate == MaxHole native; no resample needed
FRAME_MS = 20
GATE_HOLD = 1.2  # s — half-duplex loop-break (see Bridge.on_capture)

log = logging.getLogger("maxaudiod")

# ---------------------------------------------------------------- status heartbeat
# Written every 2 s so the MAXBar menu-bar widget (and humans) can observe the
# door link without opening any audio stream. Consume freshness: ts older than
# ~3 intervals => daemon is gone. Schema is flat JSON; see mac/maxbar/.
STATUS_DIR = os.path.join(os.path.expanduser("~"), "Library", "Application Support", "MaxPresence")
STATUS_PATH = os.path.join(STATUS_DIR, "maxaudiod.json")


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
#   {"link":"up"|"down", "mute_mic":bool, "mute_uplink":bool}
# polled every heartbeat tick; absent file = all permissive defaults.
CMD_PATH = os.path.join(STATUS_DIR, "cmd-maxaudiod.json")


class Controls:
    def __init__(self):
        self.link = "up"
        self.mute_mic = False
        self.mute_uplink = False
        self._mtime = None

    def poll(self):
        try:
            m = os.stat(CMD_PATH).st_mtime
        except OSError:
            if self._mtime is not None:
                log.info("cmd file gone - controls reset to defaults")
                self.__init__()
                status.bump(link_requested="up", mic_muted=False, uplink_muted=False)
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
            log.info("controls: link=%s mute_mic=%s mute_uplink=%s",
                     self.link, self.mute_mic, self.mute_uplink)
        except Exception as e:
            log.warning("cmd file unreadable: %s", e)
        status.bump(link_requested=self.link, mic_muted=self.mute_mic,
                    uplink_muted=self.mute_uplink)


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
                    # energy-aware gate: plexpipe pads the downlink with
                    # silent real-time frames — gate only on actual speech
                    if len(pcm24) and float(np.sqrt(np.mean(pcm24 ** 2))) > 0.01:
                        self.last_downlink = time.time()
                        status.inc("speaking_frames")
                    self.play_q.put(pcm24)
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
                                server_down_frames=ctrl.get("down_frames"))

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

    def _play_chunk(self, play, chunk):
        """Write one downlink chunk to MAX Mic, accounting for what and how long it took.

        NOTE: a blocking write returns as soon as the device's buffer has room, NOT when the audio has
        been heard, so a short write time is normal (and was wrongly read as an underrun while
        diagnosing V03 Gate 1). What the counters are worth is the total: `play_chunks` /
        `play_samples` in the status JSON say how much of a reply actually reached the device."""
        n = int(chunk.size)
        want = n / PLAY_NATIVE
        t0 = time.time()
        play.write(chunk.reshape(-1, 1))
        dt = time.time() - t0
        self.play_i += 1
        self.play_samples += n
        self.play_write_s += dt
        status.inc("play_chunks")
        status.bump(play_samples=int(self.play_samples))
        if self.play_i % 100 == 0:                  # one line per ~8 s of playback
            log.info("play #%d: %d samples (%.0f ms), write %.0f ms, queue %d, handed over %.2f s",
                     self.play_i, n, want * 1e3, dt * 1e3, self.play_q.qsize(),
                     self.play_samples / PLAY_NATIVE)

    def _play_summary(self):
        log.info("playback session end: %d chunks, %.2f s handed to MAX Mic, %.2f s spent in write()",
                 self.play_i, self.play_samples / PLAY_NATIVE, self.play_write_s)

    # -- audio side
    def run(self):
        self.play_q = queue.Queue(maxsize=50)
        mic_idx = find_device(MIC, "output")
        out_idx = find_device(OUT, "input")
        cap_frames = int(CAP_RATE * FRAME_MS / 1000)
        # playback accounting (V03 Gate 1 diagnosis): how much of a reply THIS side was handed, and
        # how long the device made us wait for it. A brain that generates faster than real time
        # delivers a whole reply in a burst of large chunks, so write() must be the thing that paces
        # playback; if it returns in far less than the audio's own length the device is not pacing it
        # and the audio is being dropped, not played. One summary line per session, plus a warning
        # only for a chunk that came back suspiciously fast.
        self.play_i = 0
        self.play_samples = 0
        self.play_write_s = 0.0

        def on_capture(indata, frames, tsi, status_info):
            # HALF-DUPLEX GATE (2026-11-12): Meet plays back Max's own voice
            # through the speaker path straight into MAX Out, so plexpipe
            # hears Max and answers itself — a self-sustaining loop (observed
            # live: downlink frame rate climbs with no human speaking).
            # While a downlink chunk is recent, uplink is silenced. Trade-off:
            # other participants are also muted while Max talks; permanent
            # fix is server-side AEC/gating at P4 (doc pitfall).
            status.inc("tx_frames")
            if controls.mute_uplink or (self.gate and time.time() - self.last_downlink < GATE_HOLD):
                status.inc("gated_frames")
                self.tx.put(b"A" + (b"\x00" * 2 * frames))
                return
            mono = (indata[:, 0] + indata[:, 1]) * 0.5  # L+R downmix
            pcm = (np.clip(mono, -1, 1) * 32767).astype("<i2")  # s16le 48k mono
            self.tx.put(b"A" + pcm.tobytes())

        rx_thread = threading.Thread(target=self.reader, daemon=True)
        with sd.InputStream(samplerate=CAP_RATE, device=out_idx, channels=2,
                            blocksize=cap_frames, callback=on_capture):
            with sd.OutputStream(samplerate=PLAY_NATIVE, device=mic_idx, channels=1) as play:
                rx_thread.start()
                self.play_q_idle_since = None
                try:
                    self._play_loop(play)
                finally:
                    self._play_summary()

    def _play_loop(self, play):
        while not self.stop.is_set():
            while not self.tx.empty():
                try:
                    self.ws.send(self.tx.get_nowait(), opcode=websocket.ABNF.OPCODE_BINARY)
                except Exception as e:
                    status.bump(connected=False)
                    status.inc("errors")
                    log.warning("door send failed: %s", e)
                    raise
            try:
                chunk = self.play_q.get(timeout=0.05)
                if controls.mute_mic:
                    pass  # drained, not played: MAX Mic stays silent
                else:
                    self._play_chunk(play, chunk)
            except queue.Empty:
                pass
            if controls.link == "down":
                log.info("link down requested - dropping door socket")
                if self.ws is not None:
                    try:
                        self.ws.close()
                    except Exception:
                        pass
                return

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
