#!/usr/bin/env python3
"""maxaudiod — MaxPresence Mac audio bridge (P1 prototype).

Modes:
  loopback-test   verify MaxHole devices form two ISOLATED pipes (no server, no door)
  run --door URL  bridge MAX Out (capture) -> WSS 'A' uplink 48k s16le mono,
                  WSS downlink 'A' 24k s16le mono -> MAX Mic playback
                  protocol: docs/mac-virtual-devices-plan.md (JSON control + binary tag 'A'/'V')

Native rates dodge resampling: capture 48k, play downlink at 24k (MaxHole kSampleRates).
"""
import argparse, json, logging, math, queue, sys, threading, time
import numpy as np
import sounddevice as sd
import websocket  # websocket-client

MIC = "MAX Mic"     # our write target; meeting app reads its INPUT side
OUT = "MAX Out"     # our read target; meeting app writes to its OUTPUT side
CAP_RATE = 48000
PLAY_NATIVE = 24000  # downlink rate == MaxHole native; no resample needed
FRAME_MS = 20

log = logging.getLogger("maxaudiod")


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
    def __init__(self, door):
        self.door = door
        self.tx = queue.Queue()
        self.ws = None
        self.stop = threading.Event()

    # -- websocket side
    def connect(self):
        self.ws = websocket.WebSocket()
        self.ws.connect(self.door, timeout=10)
        self.ws.send(json.dumps({"t": "hello", "v": 1, "caps": ["audio"]}))
        log.info("door connected: %s", self.door)

    def reader(self):
        while not self.stop.is_set():
            try:
                msg = self.ws.recv()
            except Exception as e:
                log.warning("door recv error: %s", e)
                return
            if isinstance(msg, bytes):
                tag, payload = msg[:1], msg[1:]
                if tag == b"A":
                    pcm24 = np.frombuffer(payload, dtype="<i2").astype(np.float32) / 32768.0
                    self.play_q.put(pcm24)
                elif tag == b"V":
                    pass  # video is P2; ignore for now
            else:
                try:
                    ctrl = json.loads(msg)
                except json.JSONDecodeError:
                    continue
                if ctrl.get("t") == "stat":
                    self.last_stat = time.time()

    # -- audio side
    def run(self):
        self.play_q = queue.Queue(maxsize=50)
        mic_idx = find_device(MIC, "output")
        out_idx = find_device(OUT, "input")
        cap_frames = int(CAP_RATE * FRAME_MS / 1000)

        def on_capture(indata, frames, ts, status):
            mono = (indata[:, 0] + indata[:, 1]) * 0.5  # L+R downmix
            pcm = (np.clip(mono, -1, 1) * 32767).astype("<i2")  # s16le 48k mono
            self.tx.put(b"A" + pcm.tobytes())

        rx_thread = threading.Thread(target=self.reader, daemon=True)
        with sd.InputStream(samplerate=CAP_RATE, device=out_idx, channels=2,
                            blocksize=cap_frames, callback=on_capture):
            with sd.OutputStream(samplerate=PLAY_NATIVE, device=mic_idx, channels=1) as play:
                rx_thread.start()
                while not self.stop.is_set():
                    while not self.tx.empty():
                        try:
                            self.ws.send(self.tx.get_nowait(), opcode=websocket.ABNF.OPCODE_BINARY)
                        except Exception as e:
                            log.warning("door send failed: %s", e)
                            raise
                    try:
                        chunk = self.play_q.get(timeout=0.05)
                        play.write(chunk.reshape(-1, 1))
                    except queue.Empty:
                        pass

    def loop(self):
        backoff = 1
        while not self.stop.is_set():
            try:
                self.connect()
                self.run()
                backoff = 1
            except Exception as e:
                log.warning("bridge down: %s (retry in %ss)", e, backoff)
                self.stop.wait(backoff)
                backoff = min(backoff * 2, 30)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["loopback-test", "run"])
    ap.add_argument("--door", help="wss:// URL from the doc (P0 assigns it)")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(name)s %(levelname)s %(message)s")
    if args.mode == "loopback-test":
        sys.exit(loopback_test())
    if not args.door:
        raise SystemExit("run mode needs --door (see docs/mac-virtual-devices-plan.md; P0 door URL lands in the doc)")
    Bridge(args.door).loop()


if __name__ == "__main__":
    main()
