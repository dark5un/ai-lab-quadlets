"""plexpipe — MaxPresence P0 server bridge (docs/mac-virtual-devices-plan.md).

One Mac session PER ROLE over the WSS door (:8991 loopback, tailnet door
tailscale serve :8457). Protocol (JSON control + binary tag 'A'/'V'):
  C->S {"t":"hello","v":1,"caps":["audio"]|["video"]}   (role = first cap)
  C->S binary 'A' = meeting audio s16le 48k mono  (MAX Out capture)
  S->C binary 'A' = Max's voice  s16le 24k mono   (plays into MAX Mic)
  S->C binary 'V' = JPEG 640x480 frame            (-> MAX Camera, video leg)
  S->C {"t":"stat",...} ~2s heartbeats (Mac watchdog + status-bar widget)
  S->C {"t":"caption","text":...} plex monologue stream (0x02, optional UI)
  C->S {"t":"testvideo","on":true|false}  (video leg: swap the real
       server-rendered feed for an ffmpeg testsrc 'V' feed (plumbing-test
       fallback), and back with on:false)
  C->S {"t":"skin","skin":"mannequin"|"quicktalk"}  (video leg: which
       server-rendered feed to relay — mannequin = maxvid three.js
       (default), quicktalk = maxface learned-face renderer (ticket 07);
       switching is immediate, each feed relays with reconnect/backoff)

The video leg streams REAL Max frames by default: it relays JPEG frames from
the maxvid renderer (MAXVID_URL, V-6a: headless chromium of the max-headroom
app) as fast as they arrive (~20-30 fps). If maxvid is down the leg idles with
heartbeats and retries; the testvideo toggle still works as fallback
(switching back to real costs a ~2s chromium restart in maxvid — demand-driven).

Internals: 'A' uplink -> ffmpeg 48k->24k -> sphn OpusStreamWriter ->
personaplex 0x01+Ogg (framing mirrors duplex-bus fdb_personaplex.py, the
live-proven python mirror). plex downlink 0x01+Ogg -> sphn OpusStreamReader
-> PCM fan-out: (1) 'A' downlink to the Mac, (2) max-bridge /feed (lips),
(3) maxface /audio-in (learned-face renderer; persistent like the bridge
feed, cheap no-op while maxface is down).
While the uplink starves we pad silence so both streams stay continuous
(full-duplex plex + A2F NIM low-fps rule).

persona voice/text prompts are env-overridable; zero auth here by design:
loopback bind + tailnet-only door (owner network policy).
"""
import asyncio
import json
import os
import time
from urllib.parse import quote

import numpy as np
import sphn
import websockets

PORT = int(os.environ.get("PLEXPIPE_PORT", "8991"))
PLEX_URL = os.environ.get("PLEX_URL", "ws://systemd-personaplex:8998")
BRIDGE_URL = os.environ.get("BRIDGE_URL", "ws://systemd-max-bridge:8990")
MAXVID_URL = os.environ.get("MAXVID_URL", "ws://systemd-maxvid:8992/frames")
MAXFACE_URL = os.environ.get("MAXFACE_URL", "ws://systemd-maxface:8993/frames")
MAXFACE_AUDIO_URL = os.environ.get("MAXFACE_AUDIO_URL", "ws://systemd-maxface:8993/audio-in")
TEXT_PROMPT = os.environ.get("PLEX_TEXT_PROMPT", "You enjoy having a good conversation.")
VOICE_PROMPT = os.environ.get("PLEX_VOICE_PROMPT", "pxvoice.wav")

UP_SR = 48000   # door uplink rate (MAX Out native)
SR = 24000      # plex native == door downlink rate (maxaudiod plays natively)
FRAME = 1920    # 80 ms at 24k
FRAME_BYTES = FRAME * 2
STAT_EVERY = 2.0
RECONNECT_MAX = 15.0

sessions = {}  # role ("audio"/"video") -> ws ; one Mac per role at a time


def log(*a):
    print("[plexpipe]", *a, flush=True)


class BridgeFeed:
    """Persistent max-bridge /feed connection: JSON header then PCM chunks."""

    def __init__(self):
        self.q: asyncio.Queue = asyncio.Queue(maxsize=200)
        self.up = False

    async def run(self, stop: asyncio.Event):
        while not stop.is_set():
            try:
                async with websockets.connect(BRIDGE_URL + "/feed") as ws:
                    await ws.send(json.dumps({"rate": SR}))
                    self.up = True
                    log("bridge feed connected")
                    while not stop.is_set():
                        try:
                            chunk = await asyncio.wait_for(self.q.get(), timeout=0.5)
                        except asyncio.TimeoutError:
                            continue
                        await ws.send(chunk)
            except Exception as e:
                self.up = False
                if stop.is_set():
                    break
                log(f"bridge feed down: {e!r}")
                await asyncio.sleep(1.0)
        self.up = False

    def push(self, pcm16: bytes):
        try:
            self.q.put_nowait(pcm16)
        except asyncio.QueueFull:
            pass  # drop oldest-facing: lips animation is best-effort


class PcmFeed:
    """Persistent maxface /audio-in connection: JSON header then PCM chunks.
    Mirror of BridgeFeed — the learned-face renderer taps the same downlink."""

    def __init__(self, url: str, label: str):
        self.url = url
        self.label = label
        self.q: asyncio.Queue = asyncio.Queue(maxsize=200)
        self.up = False

    async def run(self, stop: asyncio.Event):
        while not stop.is_set():
            try:
                async with websockets.connect(self.url) as ws:
                    await ws.send(json.dumps({"rate": SR}))
                    self.up = True
                    log(f"{self.label} feed connected")
                    while not stop.is_set():
                        try:
                            chunk = await asyncio.wait_for(self.q.get(), timeout=0.5)
                        except asyncio.TimeoutError:
                            continue
                        await ws.send(chunk)
            except Exception as e:
                self.up = False
                if stop.is_set():
                    break
                log(f"{self.label} feed down: {e!r}")
                await asyncio.sleep(1.0)
        self.up = False

    def push(self, pcm16: bytes):
        try:
            self.q.put_nowait(pcm16)
        except asyncio.QueueFull:
            pass  # renderer is best-effort: drop like the lips feed


async def plex_session(ws, stop: asyncio.Event, stats: dict,
                       ff_buf: bytearray, bridge: "BridgeFeed",
                       renderer: "PcmFeed"):
    """Dial personaplex and run the duplex loop for one Mac session."""
    url = f"{PLEX_URL}/api/chat?text_prompt={quote(TEXT_PROMPT)}&voice_prompt={quote(VOICE_PROMPT)}"
    ow = sphn.OpusStreamWriter(SR)
    ordr = sphn.OpusStreamReader(SR)
    silence = np.zeros(FRAME, np.float32)

    while not stop.is_set():
        try:
            plex = await websockets.connect(url, max_size=None)
        except Exception as e:
            log(f"plex dial failed: {e!r}")
            await asyncio.sleep(min(RECONNECT_MAX, 1.0))
            stats["plex_up"] = False
            continue
        hs = await plex.recv()
        if hs != b"\x00":
            log(f"bad plex handshake: {hs!r}")
            await plex.close()
            await asyncio.sleep(1.0)
            continue
        stats["plex_up"] = True
        log("plex streaming")
        try:
            # uplink pump: 80 ms ticks -> ff-resampled frames (or silence pad)
            async def up_pump():
                while not stop.is_set():
                    while len(ff_buf) >= FRAME_BYTES:
                        frame = bytes(ff_buf[:FRAME_BYTES])
                        del ff_buf[:FRAME_BYTES]
                        pcm = np.frombuffer(frame, dtype="<i2").astype(np.float32) / 32768.0
                        ow.append_pcm(pcm)
                    if not len(ff_buf) and stats["up_bytes"] == stats.get("up_bytes_mark", -1):
                        ow.append_pcm(silence)  # starved uplink: keep stream continuous
                    stats["up_bytes_mark"] = stats["up_bytes"]
                    b = ow.read_bytes()
                    if b:
                        await plex.send(b"\x01" + b)
                    await asyncio.sleep(0.08)

            async def down_pump():
                async for msg in plex:
                    if not isinstance(msg, (bytes, bytearray)) or not msg:
                        continue
                    if msg[0] == 0x01:
                        ordr.append_bytes(msg[1:])
                        pcm = ordr.read_pcm()
                        if pcm is None:
                            continue
                        if pcm.ndim > 1:
                            pcm = pcm.reshape(-1)
                        s16 = (pcm * 32768).astype("<i2").tobytes()
                        stats["down_bytes"] += len(s16)
                        stats["down_frames"] += 1
                        bridge.push(s16)
                        renderer.push(s16)
                        try:
                            await ws.send(b"A" + s16)
                        except Exception:
                            stop.set()
                            return
                    elif msg[0] == 0x02:
                        try:
                            await ws.send(json.dumps(
                                {"t": "caption", "text": msg[1:].decode("utf-8", "replace")}))
                        except Exception:
                            stop.set()
                            return
                    elif msg[0] == 0x05:
                        log(f"plex error: {msg[1:].decode(errors='replace')}")

            t1, t2 = asyncio.create_task(up_pump()), asyncio.create_task(down_pump())
            done, _ = await asyncio.wait({t1, t2}, return_when=asyncio.FIRST_COMPLETED)
            for t in (t1, t2):
                t.cancel()
            ended = "up" if t1 in done else "down"
            exc = next(iter(done)).exception()
            log(f"plex ended ({ended}): exc={exc!r} rcvd={getattr(plex, 'rcvd', None)}")
        except Exception as e:
            log(f"plex loop broke: {e!r}")
            try:
                log(f"plex close: rcvd={e.rcvd} sent={e.sent}")  # type: ignore[attr-defined]
            except AttributeError:
                pass
        finally:
            stats["plex_up"] = False
            try:
                # SHIELDED: task cancel must not skip the close — personaplex
                # holds one global lock per session; a leaked socket wedges
                # every future dial (hit live 2026-11-12 during P0 testing).
                await asyncio.shield(plex.close())
            except Exception:
                pass
            if not stop.is_set():
                await asyncio.sleep(1.0)


async def handle(ws):
    # --- hello handshake: first frame must be JSON {"t":"hello","v":1,caps:[...]}
    try:
        first = await asyncio.wait_for(ws.recv(), timeout=10)
    except Exception:
        return
    try:
        hello = json.loads(first)
    except (json.JSONDecodeError, TypeError):
        await ws.close(code=1002, reason="hello-first")
        return
    if hello.get("t") != "hello" or hello.get("v") != 1:
        await ws.close(code=1002, reason="bad-hello")
        return
    caps = hello.get("caps") or ["audio"]
    role = next((c for c in ("audio", "video") if c in caps), None)
    if role is None:
        await ws.close(code=1002, reason="no-recognized-caps")
        return
    if sessions.get(role) is not None:
        log(f"rejecting second '{role}' session (one Mac per role)")
        try:
            await ws.send(json.dumps({"t": "bye", "reason": "busy"}))
        except Exception:
            pass
        await ws.close(code=1008, reason="busy")
        return
    sessions[role] = ws
    peer = ws.remote_address
    log(f"session open from {peer} caps={caps} role={role}")
    if role == "video":
        try:
            await video_session(ws, peer)
        finally:
            sessions["video"] = None
        return

    stop = asyncio.Event()
    stats = {"t0": time.time(), "up_bytes": 0, "down_bytes": 0,
             "up_frames": 0, "down_frames": 0, "video_frames": 0,
             "plex_up": False, "bridge_up": False, "renderer_up": False}
    bridge = BridgeFeed()
    renderer = PcmFeed(MAXFACE_AUDIO_URL, "maxface")
    ff_buf = bytearray()

    ff = await asyncio.create_subprocess_exec(
        "ffmpeg", "-loglevel", "error",
        "-f", "s16le", "-ar", str(UP_SR), "-ac", "1", "-i", "pipe:0",
        "-af", "aresample", "-ar", str(SR), "-ac", "1", "-f", "s16le", "pipe:1",
        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE)

    async def ff_reader():
        while not stop.is_set():
            chunk = await ff.stdout.read(FRAME_BYTES * 4)
            if not chunk:
                break
            ff_buf.extend(chunk)

    async def door_reader():
        async for msg in ws:
            if isinstance(msg, (bytes, bytearray)) and msg[:1] == b"A":
                stats["up_bytes"] += len(msg) - 1
                stats["up_frames"] += 1
                try:
                    ff.stdin.write(msg[1:])
                    await ff.stdin.drain()
                except (BrokenPipeError, ConnectionResetError):
                    break
            elif isinstance(msg, str):
                try:
                    ctrl = json.loads(msg)
                except json.JSONDecodeError:
                    continue
                if ctrl.get("t") == "bye":
                    break

    async def heartbeat():
        while not stop.is_set():
            stats["bridge_up"] = bridge.up
            stats["renderer_up"] = renderer.up
            payload = {k: v for k, v in stats.items()
                       if not k.startswith("_") and k != "up_bytes_mark"}
            payload["t"] = "stat"
            payload["session_s"] = round(time.time() - stats["t0"], 1)
            try:
                await ws.send(json.dumps(payload))
            except Exception:
                break
            await asyncio.sleep(STAT_EVERY)

    tasks = [asyncio.create_task(c) for c in
             (bridge.run(stop), renderer.run(stop),
              plex_session(ws, stop, stats, ff_buf, bridge, renderer),
              ff_reader(), door_reader(), heartbeat())]
    done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    # door_reader or plex_session finishing ends the session
    stop.set()
    for t in tasks:
        t.cancel()
    try:
        ff.stdin.close()
    except Exception:
        pass
    ff.kill()
    await ff.wait()
    sessions["audio"] = None
    log(f"session closed from {peer} stats="
        f"{ {k: stats[k] for k in ('up_bytes', 'down_bytes', 'plex_up')} }")


async def relay_feed(ws, stop: asyncio.Event, stats: dict, url: str, label: str):
    """Relay JPEG frames from a renderer (maxvid mannequin / maxface
    QuickTalk) as 'V', with reconnect + backoff."""
    backoff = 1.0
    while not stop.is_set():
        try:
            async with websockets.connect(url, max_size=2**22) as vws:
                log(f"{label} feed connected ({url})")
                stats["video_source"] = label
                backoff = 1.0
                async for msg in vws:
                    if stop.is_set():
                        break
                    if isinstance(msg, (bytes, bytearray)):
                        stats["video_frames"] += 1
                        await ws.send(b"V" + msg)
                    elif isinstance(msg, str):
                        try:
                            stats["renderer_stat"] = json.loads(msg)
                        except json.JSONDecodeError:
                            pass
        except Exception as e:
            if stop.is_set():
                break
            stats["video_source"] = "down"
            log(f"{label} feed down: {e!r}; retry in {backoff:.0f}s")
            await asyncio.sleep(backoff)
            backoff = min(RECONNECT_MAX, backoff * 2)


async def video_session(ws, peer):
    """Video leg (MAX Camera extension): stat heartbeat + 'V' JPEG frames.
    Default feed = real server-rendered Max (mannequin = maxvid); the
    {"t":"skin"} control swaps between mannequin and quicktalk (maxface)
    renders, and the legacy {"t":"testvideo"} control swaps in an ffmpeg
    testsrc feed (plumbing-test fallback) and back."""
    stop = asyncio.Event()
    stats = {"t0": time.time(), "video_frames": 0, "video_source": "mannequin"}
    feed_task: asyncio.Task | None = None
    feed_mode = ["mannequin"]

    def switch_feed(mode: str):
        nonlocal feed_task
        if feed_task is not None and not feed_task.done():
            feed_task.cancel()
        feed_mode[0] = mode
        if mode == "testsrc":
            stats["video_source"] = "testsrc"
            feed_task = asyncio.create_task(test_feed())
        elif mode == "quicktalk":
            stats["video_source"] = "quicktalk"
            feed_task = asyncio.create_task(
                relay_feed(ws, stop, stats, MAXFACE_URL, "quicktalk"))
        else:
            stats["video_source"] = "mannequin"
            feed_task = asyncio.create_task(
                relay_feed(ws, stop, stats, MAXVID_URL, "mannequin"))
        log(f"video feed = {mode}")

    async def heartbeat():
        while not stop.is_set():
            payload = {"t": "stat", "video_frames": stats["video_frames"],
                       "video_source": stats["video_source"],
                       "renderer": stats.get("renderer_stat"),
                       "session_s": round(time.time() - stats["t0"], 1)}
            try:
                await ws.send(json.dumps(payload))
            except Exception:
                break
            await asyncio.sleep(STAT_EVERY)

    async def test_feed():
        proc = await asyncio.create_subprocess_exec(
            "ffmpeg", "-loglevel", "error", "-re",
            "-f", "lavfi", "-i", "testsrc=size=640x480:rate=30",
            "-f", "image2pipe", "-vcodec", "mjpeg", "-q:v", "6", "pipe:1",
            stdout=asyncio.subprocess.PIPE)
        out = proc.stdout
        assert out is not None
        buf = bytearray()
        try:
            while not stop.is_set():
                chunk = await out.read(8192)
                if not chunk:
                    break
                buf.extend(chunk)
                while True:
                    eoi = buf.find(b"\xff\xd9")
                    if eoi < 0:
                        break
                    jpeg = bytes(buf[: eoi + 2])
                    del buf[: eoi + 2]
                    stats["video_frames"] += 1
                    await ws.send(b"V" + jpeg)
        except (asyncio.CancelledError, Exception) as e:
            if not isinstance(e, asyncio.CancelledError):
                log(f"test feed broke: {e!r}")
        finally:
            proc.kill()
            await proc.wait()

    async def control_reader():
        nonlocal feed_task
        async for msg in ws:
            if not isinstance(msg, str):
                continue
            try:
                ctrl = json.loads(msg)
            except json.JSONDecodeError:
                continue
            if ctrl.get("t") == "bye":
                break
            if ctrl.get("t") == "testvideo":
                want = "testsrc" if ctrl.get("on") else "mannequin"
                if feed_mode[0] != want:
                    switch_feed(want)
            if ctrl.get("t") == "skin":
                want = ("quicktalk" if ctrl.get("skin") == "quicktalk"
                        else "mannequin")
                if feed_mode[0] != want:
                    switch_feed(want)

    switch_feed("real")  # default: server-rendered Max
    tasks = [asyncio.create_task(c) for c in (heartbeat(), control_reader())]
    await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    stop.set()
    if feed_task and not feed_task.done():
        feed_task.cancel()
    for task in tasks:
        task.cancel()
    log(f"video session closed from {peer} frames={stats['video_frames']}")


async def main():
    async with websockets.serve(handle, "0.0.0.0", PORT, max_size=2**22):
        log(f"listening on :{PORT} (plex={PLEX_URL} bridge={BRIDGE_URL})")
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
