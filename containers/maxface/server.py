"""maxface — MaxPresence ticket-07 renderer: QuickTalk face over the door 'V' leg.

Consumes plexpipe's downlink speech PCM (s16le 24k mono, pushed to /audio-in)
and streams JPEG frames on /frames with the SAME contract as maxvid, so
plexpipe can relay either skin. Frames: 640x480 (aspect-preserved letterbox).

Skin semantics (full CFR/backpressure pacing lands in ticket 08):
  * speech  -> QuickTalk regeneration frames (RealtimeV3Worker, per-frame
               LSTM state, chunked by MAXFACE_SLICE_LEN frames of audio)
  * idle    -> the anchor idle-loop: template frames cycling ping-pong
               (no model call; identity-stable by construction)

QuickTalk runtime facts this service depends on (docs-first, code-cited in
~/Documents/Hermes/2026-11-12-maxpresence-p1-mac/quicktalk-liveportrait-notes.md):
  * production device is CUDA (Apple Silicon = dev-only per official docs)
  * worker keeps template frames + restore contexts resident (the expensive
    build), sessions keep their own state
  * HuBERT frontend takes any PCM rate (resamples internally); CUDA path runs
    it in fp16
  * model_backend auto -> checkpoints/quicktalk.pth (TorchScript)

Protocol (JSON control + raw binary PCM, mirrors plexpipe's BridgeFeed push):
  plexpipe -> /audio-in : {"rate":24000} then binary s16le chunks
  client   -> /frames   : binary JPEG pushed per frame (like maxvid)
  stat control frames {"t":"stat",...} on /frames every 2 s (source, fps,
  speech/idle counters) so the door-side probe can verify the feed.
Zero auth by design: ai.network-internal only (never host-published).
"""
import asyncio
import json
import logging
import os
import time
from collections import deque
from pathlib import Path

import cv2
import numpy as np
import websockets

logging.basicConfig(level=logging.INFO, format="[maxface] %(message)s")
log = logging.getLogger("maxface")

PORT = int(os.environ.get("MAXFACE_PORT", "8993"))
ASSET_ROOT = os.environ.get("OPENTALKING_QUICKTALK_ASSET_ROOT",
                            os.path.expanduser("~/.local/share/maxface/quicktalk"))
TEMPLATE = os.environ.get("MAXFACE_TEMPLATE",
                          os.path.expanduser("~/.local/share/maxface/avatars/maximilian/source/maximilian_livetune10.mp4"))
DEVICE = os.environ.get("MAXFACE_DEVICE", "cuda:0")
FACE_CACHE_DIR = (Path(p) if (p := os.environ.get("MAXFACE_FACE_CACHE_DIR", "").strip()) else None)
FPS = int(os.environ.get("OPENTALKING_QUICKTALK_FPS", "25"))
SLICE_LEN = int(os.environ.get("MAXFACE_SLICE_LEN", "6"))          # frames of audio per generation call (0.24 s): lip-latency vs HuBERT efficiency; pacing/compensation lands in ticket 08
IN_RATE = int(os.environ.get("MAXFACE_IN_RATE", "24000"))           # door downlink rate
FEAT_RATE = 16000   # HuBERT frontend is 16k-hard (Wav2Vec2FeatureExtractor
                    # raises on other sampling_rate) -> slices resampled per call
OUT_W, OUT_H = 640, 480                                             # door 'V' contract
JPEG_QUALITY = int(os.environ.get("MAXFACE_JPEG_QUALITY", "82"))
SILENCE_RMS = float(os.environ.get("MAXFACE_SILENCE_RMS", "300"))   # int16 RMS gate (~ -40 dBFS)
FRAME_CAP = int(os.environ.get("MAXFACE_FRAME_CAP", "60"))          # drop-oldest watermark
AUDIO_MAX_S = float(os.environ.get("MAXFACE_AUDIO_MAX_S", "4.0"))   # ring buffer cap
STAT_EVERY = 2.0

MAXFACE_SLICE_SAMPLES = int(round(IN_RATE * SLICE_LEN / float(FPS)))


class Engine:
    """RealtimeV3Worker resident; heavy build once, then per-slice generation."""

    def __init__(self):
        self.ready = False
        self.worker = None
        self.state = None
        self.last_error: str | None = None
        self.stats = {"speech_frames": 0, "idle_frames": 0, "slices": 0,
                      "slice_seconds": 0.0}

    def build(self):
        # Heavy import kept local so startup logs stay readable.
        from opentalking.models.quicktalk.runtime import RealtimeV3Worker

        log.info("loading QuickTalk worker device=%s template=%s", DEVICE, TEMPLATE)
        t0 = time.perf_counter()
        self.worker = RealtimeV3Worker(
            asset_root=Path(ASSET_ROOT),
            template_video=Path(TEMPLATE),
            face_cache_dir=FACE_CACHE_DIR,
            device=DEVICE,
            output_transform="bgr",
        )
        self.state = self.worker.make_state()
        self.ready = True
        log.info("QuickTalk worker ready in %.1fs frames=%d fps=%s",
                 time.perf_counter() - t0, len(self.worker.frames), self.worker.fps)

    def idle_frame(self):
        n = len(self.worker.restore_contexts)
        cycle = self.state.frame_index // n
        offset = self.state.frame_index % n
        idx = offset if cycle % 2 == 0 else n - 1 - offset
        self.state.frame_index += 1
        frame = self.worker.restore_contexts[idx].frame
        self.stats["idle_frames"] += 1
        return frame

    def render_slice(self, pcm: np.ndarray):
        """One speech slice -> generated frames (blocking; runs in a thread)."""
        from scipy.signal import resample_poly

        t0 = time.perf_counter()
        if IN_RATE != FEAT_RATE:
            from math import gcd
            d = gcd(IN_RATE, FEAT_RATE)
            pcm = resample_poly(pcm.astype(np.float64),
                                FEAT_RATE // d, IN_RATE // d).astype(np.int16)
        reps, _feat_s = self.worker.prepare_pcm_features(pcm, FEAT_RATE)
        out = []
        for frame in self.worker.generate_frames_from_reps(reps, state=self.state):
            out.append(frame)
        self.stats["slices"] += 1
        self.stats["slice_seconds"] += time.perf_counter() - t0
        self.stats["speech_frames"] += len(out)
        return out


def to_door_frame(frame: np.ndarray) -> bytes:
    """Letterbox any worker frame to the 640x480 'V' contract, JPEG."""
    h, w = frame.shape[:2]
    scale = min(OUT_W / w, OUT_H / h)
    nw, nh = int(round(w * scale)), int(round(h * scale))
    small = cv2.resize(frame, (nw, nh), interpolation=cv2.INTER_AREA)
    canvas = np.zeros((OUT_H, OUT_W, 3), np.uint8)
    y0 = (OUT_H - nh) // 2
    x0 = (OUT_W - nw) // 2
    canvas[y0:y0 + nh, x0:x0 + nw] = small
    ok, jpg = cv2.imencode(".jpg", canvas,
                           [int(cv2.IMWRITE_JPEG_QUALITY), JPEG_QUALITY])
    if not ok:
        raise RuntimeError("jpeg encode failed")
    return jpg.tobytes()


class Feed:
    """Shared renderer state: PCM ring + pending frames + subscriber set."""

    def __init__(self, engine: Engine):
        self.engine = engine
        self.audio = np.zeros(0, np.int16)
        self.pending: deque[bytes] = deque()
        self.subscribers: set = set()
        self.speaking = False
        self.last_audio_at = 0.0

    def push_pcm(self, chunk: np.ndarray):
        self.audio = np.concatenate([self.audio, chunk])
        cap = int(IN_RATE * AUDIO_MAX_S)
        if self.audio.size > cap:
            self.audio = self.audio[-cap:]
        self.last_audio_at = time.time()

    def take_slice(self) -> np.ndarray | None:
        if self.audio.size < MAXFACE_SLICE_SAMPLES:
            return None
        s = self.audio[:MAXFACE_SLICE_SAMPLES]
        self.audio = self.audio[MAXFACE_SLICE_SAMPLES:]
        return s


async def main():
    engine = Engine()
    feed = Feed(engine)
    loop = asyncio.get_running_loop()

    async def build_engine():
        try:
            await loop.run_in_executor(None, engine.build)
        except Exception as e:  # noqa: BLE001
            engine.last_error = repr(e)
            log.exception("worker build failed")

    async def audio_in(ws):
        """plexpipe /audio-in: JSON header then binary s16le chunks."""
        first = await asyncio.wait_for(ws.recv(), timeout=10)
        try:
            hdr = json.loads(first)
            rate = int(hdr.get("rate", IN_RATE))
            if rate != IN_RATE:
                await ws.close(code=1002, reason=f"rate {rate} != {IN_RATE}")
                return
        except (json.JSONDecodeError, TypeError, ValueError):
            await ws.close(code=1002, reason="header-first")
            return
        log.info("audio-in connected from %s", ws.remote_address)
        try:
            async for msg in ws:
                if isinstance(msg, (bytes, bytearray)):
                    feed.push_pcm(np.frombuffer(msg, dtype="<i2"))
        except websockets.ConnectionClosed:
            pass
        finally:
            log.info("audio-in closed")

    async def frames(ws):
        """maxvid-compatible /frames: JPEG bytes pushed per tick + stat ctrl."""
        feed.subscribers.add(ws)
        log.info("frames subscriber %s (%d total)", ws.remote_address, len(feed.subscribers))
        try:
            async for msg in ws:
                if isinstance(msg, str) and json.loads(msg).get("t") == "bye":
                    break
        except websockets.ConnectionClosed:
            pass
        finally:
            feed.subscribers.discard(ws)
            log.info("frames subscriber left (%d total)", len(feed.subscribers))

    async def dispatch(ws):
        path = getattr(ws, "request", None)
        p = path.path if path is not None else getattr(ws, "path", "/")
        if p == "/audio-in":
            await audio_in(ws)
        elif p == "/frames":
            await frames(ws)
        else:
            await ws.close(code=1002, reason="use /frames or /audio-in")

    async def heartbeat():
        while True:
            payload = {"t": "stat", "source": "quicktalk", "ready": engine.ready,
                       "fps": FPS, "slice_len": SLICE_LEN,
                       "speaking": feed.speaking,
                       "pending": len(feed.pending),
                       "subscribers": len(feed.subscribers),
                       "audio_pending_ms": round(1000 * feed.audio.size / IN_RATE),
                       "seconds_since_audio": round(time.time() - feed.last_audio_at, 1),
                       **{k: (round(v, 2) if isinstance(v, float) else v)
                          for k, v in engine.stats.items()}}
            if engine.last_error:
                payload["error"] = engine.last_error
            dead = set()
            for ws in feed.subscribers:
                try:
                    await ws.send(json.dumps(payload))
                except Exception:
                    dead.add(ws)
            feed.subscribers -= dead
            await asyncio.sleep(STAT_EVERY)

    async def emitter():
        """25 fps CFR pump: pending generated frames, else idle-loop frames."""
        tick = 1.0 / FPS
        render_busy = False
        while True:
            t0 = time.perf_counter()
            # kick one render slice when audio + queue allow it (watermark gate)
            if engine.ready and not render_busy and len(feed.pending) < FRAME_CAP:
                s = feed.take_slice()
                if s is not None and np.sqrt(np.mean(s.astype(np.float64) ** 2)) > SILENCE_RMS:
                    feed.speaking = True

                    def run(s=s):
                        return engine.render_slice(s)

                    def done(fut):
                        nonlocal render_busy
                        render_busy = False
                        try:
                            frames_ = fut.result()
                        except Exception:
                            log.exception("slice render failed")
                            return
                        for f in frames_:
                            feed.pending.append(to_door_frame(f))
                        while len(feed.pending) > FRAME_CAP:
                            feed.pending.popleft()

                    render_busy = True
                    fut = loop.run_in_executor(None, run)
                    fut.add_done_callback(
                        lambda f: loop.call_soon_threadsafe(done, f))
                else:
                    if s is not None:
                        feed.speaking = False
                    elif time.time() - feed.last_audio_at > 2.0:
                        feed.speaking = False
            frame = None
            if feed.pending:
                frame = feed.pending.popleft()
            elif engine.ready:
                frame = to_door_frame(engine.idle_frame())
            if frame is not None:
                dead = set()
                for ws in feed.subscribers:
                    try:
                        await ws.send(frame)
                    except Exception:
                        dead.add(ws)
                feed.subscribers -= dead
            dt = time.perf_counter() - t0
            await asyncio.sleep(max(0.0, tick - dt))

    await build_engine()
    async with websockets.serve(dispatch, "0.0.0.0", PORT, max_size=2 ** 22):
        log.info("maxface listening on :%d (/frames /audio-in)", PORT)
        await asyncio.gather(emitter(), heartbeat())


if __name__ == "__main__":
    asyncio.run(main())
