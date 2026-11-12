"""plexpipe — MaxPresence P0 server bridge (docs/mac-virtual-devices-plan.md).

One Mac session at a time over the WSS door (:8991 loopback, tailnet door
tailscale serve :8457). Protocol (JSON control + binary tag 'A'/'V'):
  C->S {"t":"hello","v":1,"caps":["audio","video"]}
  C->S binary 'A' = meeting audio s16le 48k mono  (MAX Out capture)
  S->C binary 'A' = Max's voice  s16le 24k mono   (plays into MAX Mic)
  S->C {"t":"stat",...} ~2s heartbeats (Mac watchdog + status-bar widget)
  S->C {"t":"caption","text":...} plex monologue stream (0x02, optional UI)
  'V' JPEG downlink is reserved for P2 (maxaudiod ignores it until then).

Internals: 'A' uplink -> ffmpeg 48k->24k -> sphn OpusStreamWriter ->
personaplex 0x01+Ogg (framing mirrors duplex-bus fdb_personaplex.py, the
live-proven python mirror). plex downlink 0x01+Ogg -> sphn OpusStreamReader
-> PCM fan-out: (1) 'A' downlink to the Mac, (2) max-bridge /feed (lips).
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
TEXT_PROMPT = os.environ.get("PLEX_TEXT_PROMPT", "You enjoy having a good conversation.")
VOICE_PROMPT = os.environ.get("PLEX_VOICE_PROMPT", "pxvoice.wav")

UP_SR = 48000   # door uplink rate (MAX Out native)
SR = 24000      # plex native == door downlink rate (maxaudiod plays natively)
FRAME = 1920    # 80 ms at 24k
FRAME_BYTES = FRAME * 2
STAT_EVERY = 2.0
RECONNECT_MAX = 15.0

active_session = None  # one Mac at a time


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


async def plex_session(ws, stop: asyncio.Event, stats: dict,
                       ff_buf: bytearray, bridge: "BridgeFeed"):
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
    global active_session
    # --- hello handshake: first frame must be JSON {"t":"hello","v":1,...}
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
    if active_session is not None:
        log("rejecting second session (one Mac at a time)")
        try:
            await ws.send(json.dumps({"t": "bye", "reason": "busy"}))
        except Exception:
            pass
        await ws.close(code=1008, reason="busy")
        return
    active_session = ws
    peer = ws.remote_address
    log(f"session open from {peer} caps={hello.get('caps')}")

    stop = asyncio.Event()
    stats = {"t0": time.time(), "up_bytes": 0, "down_bytes": 0,
             "up_frames": 0, "down_frames": 0, "video_frames": 0,
             "plex_up": False, "bridge_up": False}
    bridge = BridgeFeed()
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
             (bridge.run(stop), plex_session(ws, stop, stats, ff_buf, bridge),
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
    active_session = None
    log(f"session closed from {peer} stats="
        f"{ {k: stats[k] for k in ('up_bytes', 'down_bytes', 'plex_up')} }")


async def main():
    async with websockets.serve(handle, "0.0.0.0", PORT, max_size=2**22):
        log(f"listening on :{PORT} (plex={PLEX_URL} bridge={BRIDGE_URL})")
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
