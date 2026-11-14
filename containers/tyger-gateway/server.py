"""tyger-gateway -- the `plex` upstream that plexpipe dials, speaking tyger's /ws.

plexpipe is unchanged. Per door session it dials PLEX_URL and expects the personaplex "plex" role
(containers/plexpipe/server.py:148-244): WS /api/chat?text_prompt=&voice_prompt=, a one-byte b"\x00"
handshake, then 0x01+Ogg/Opus at 24 kHz both ways. This process serves that role and carries the audio to a
tyger-s2s EARS WebSocket instead of personaplex. Contracts: WIRE-TABLES-v03.md, legs C and D.

  leg C (plex, plexpipe <-> here)   0x01 + Ogg/Opus 24 kHz mono, both ways   (plexpipe server.py:187,194-210)
  leg D (tyger /ws)  uplink         [int32 rid][int32 agent sample at 24 kHz, -1] + int16 PCM 16 kHz
                                    (app/ears/playback.py:16-18,31,45-52; 20 ms blocks = 648 B, page.py:16)
                     downlink       [int32 rid, 0 = backchannel] + int16 PCM 24 kHz (playback.py:31-32,40-42)
                     commands       played:<rid>:<samples>, reset, voice:<name>, set:<attr>:<value>

What is deliberately NOT here (PLAN-V03-step2.md §6): the CoreAudio playhead (I-26 -> step 4), the barge drain
(a barge stops this gateway's playhead and drops the rest of that reply; a real drain is step 4), secret/pages
posture (V05: this process CAN carry a token, it does not set one), and any voice-identity work.

Privacy: tyger itself logs no transcripts (app/ears/conversation.py:27). This gateway logs them, because Gate 1's
evidence is "MAX Out's transcript matches the reply text in the gateway log" (PLAN-V03-step2.md §2).
"""
from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import json
import os
import secrets
import struct
import time

import aiohttp
import numpy as np
from aiohttp import WSMsgType, web

from playhead import BACKCHANNEL_ID, Playhead
from plexio import OpusDecoder, OpusEncoder
from resample import StreamingAudioResampler

PORT = int(os.environ.get("GATEWAY_PORT", "8994"))
TYGER_WS = os.environ.get("TYGER_URL", "ws://tyger-v1:7860/ws")
TYGER_VOICES = os.environ.get("TYGER_VOICES_URL", "http://tyger-v1:7860/voices")
TYGER_SECRET = os.environ.get("TYGER_API_SECRET", "").strip() or None
# Diagnostic (off unless set): append every reply's raw Ogg/Opus payload to
# <dir>/reply-<rid>.ogg, so the audio THIS leg sends can be decoded and listened to independently of
# the door. Not evidence on its own -- the acceptance is what a human hears off MAX Mic -- but it says
# which side of plexpipe a defect is on.
DUMP_DIR = os.environ.get("GATEWAY_DUMP_DIR", "").strip() or None

SR_PLEX = 24000            # the plex leg's rate, both ways (plexpipe server.py:33,62)
BLOCK = 320                # a mic block: 20 ms at the EARS rate (page.py:16)
TOKEN_TTL_S = 60           # page.py:17
AUDIENCE = "tyger"         # app/ears/access.py:17
MIC_LOG_EVERY = 250        # one mic summary line per 5 s of uplink
DIAL_BACKOFF_MAX = 15.0    # like plexpipe's RECONNECT_MAX
HEALTH_TTL_S = 2.0

MIC_HEADER = struct.Struct("<ii")      # reply id, agent sample at 24 kHz (-1: nothing playing)
AUDIO_HEADER = struct.Struct("<i")     # the reply's id (0: a backchannel)

SESSIONS = 0               # live plex sessions (what /health reports)


def log(*a):
    print("[tyger-gateway]", *a, flush=True)


def to_pcm16(x: np.ndarray) -> np.ndarray:
    """float32 -> int16, as playback.py:36-37 does it."""
    return np.clip(np.round(x * 32767.0), -32768, 32767).astype("<i2")


def sign_token(secret: str, ttl_s: int = TOKEN_TTL_S) -> str:
    """HS256 JWT for one conversation: aud tyger, exp ttl ahead, a fresh jti (page.py:24-31, access.py:16-19).

    One token opens one conversation -- tyger spends the jti at the upgrade (access.py:77-81) -- so this is
    called per connect, never reused.
    """
    def b64(raw: bytes) -> str:
        return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")

    now = int(time.time())
    header = b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    claims = b64(json.dumps({"aud": AUDIENCE, "iat": now, "exp": now + ttl_s,
                             "jti": secrets.token_hex(16)}).encode())
    sig = hmac.new(secret.encode(), f"{header}.{claims}".encode("ascii"), hashlib.sha256).digest()
    return f"{header}.{claims}.{b64(sig)}"


class PlexSession:
    """One plexpipe session: its plex leg, its tyger leg, and the playhead between them."""

    def __init__(self, ws, http: aiohttp.ClientSession, voice_prompt: str):
        self.ws = ws
        self.http = http
        self.voice_prompt = voice_prompt
        self.stop = asyncio.Event()
        self.tyger = None
        self.tyger_ready = False
        self.sr_ears = 16000                 # corrected from `ready`
        self.blocks = 0
        self.mic_bytes = 0
        self.dropped_blocks = 0
        self.encoded_bytes = 0
        self.reply_rid = 0
        self.reply_samples = 0
        self.reply_t0 = 0.0
        self.reply_t1 = 0.0
        self.barged_rid = None
        self.state_events = 0
        self.last_state = None
        self.reply_text: str | None = None
        self.enc: OpusEncoder | None = None
        self.playhead = Playhead(self._report_played)

    async def _flush_audio(self) -> bytes:
        """Send the tail of the current reply as a whole frame (a turn boundary; see OpusEncoder.flush)."""
        ws = self.tyger
        if self.enc is None or ws is None or ws.closed:
            return b""
        payload = self.enc.flush()
        if payload:
            self.encoded_bytes += len(payload)
            try:
                await ws.send_bytes(b"\x01" + payload)
            except (ConnectionError, RuntimeError):
                pass
        return payload

    # ---- leg D: the client side of tyger's /ws ----
    async def _report_played(self, rid: int, samples: int) -> None:
        ws = self.tyger
        if ws is None or ws.closed:
            return
        try:
            await ws.send_str(f"played:{rid}:{samples}")
            log(f"played:{rid}:{samples} sent")
        except (ConnectionError, RuntimeError):
            pass

    async def tyger_manager(self):
        """Keep a tyger conversation open behind this plex leg, for as long as the plex leg lives.

        A plex leg that fails makes plexpipe redial once a second (plexpipe server.py:228-244) -- the reconnect
        storm. So this leg never fails on the brain's account: while tyger is unreachable the uplink is read and
        dropped, and the dial is retried with backoff.
        """
        backoff = 1.0
        first = True
        while not self.stop.is_set():
            url = TYGER_WS + (f"?token={sign_token(TYGER_SECRET)}" if TYGER_SECRET else "")
            if first:
                log("token: " + (f"signed per connect (aud={AUDIENCE}, ttl={TOKEN_TTL_S}s)"
                                 if TYGER_SECRET else "none (TYGER_API_SECRET unset: tyger checks no token)"))
                first = False
            try:
                ws = await self.http.ws_connect(url, max_msg_size=0)
            except Exception as e:                                  # noqa: BLE001 - any dial error retries
                log(f"tyger dial failed: {e!r}; retry in {backoff:.0f}s (uplink dropped meanwhile)")
                await asyncio.sleep(backoff)
                backoff = min(DIAL_BACKOFF_MAX, backoff * 2)
                continue
            backoff = 1.0
            try:
                await self.tyger_loop(ws)
            except Exception as e:                                  # noqa: BLE001 - log and redial
                log(f"tyger leg broke: {e!r}")
            finally:
                self.tyger_ready = False
                self.tyger = None
                try:
                    await ws.close()
                except Exception:                                   # noqa: BLE001
                    pass
            if not self.stop.is_set():
                log("tyger leg closed; redial in 1 s")
                await asyncio.sleep(1.0)

    async def tyger_loop(self, ws):
        self.tyger = ws
        self.tyger_ready = False
        self.playhead.reset()
        self.reply_rid = 0
        self.reply_samples = 0
        self.reply_t0 = self.reply_t1 = 0.0
        self.barged_rid = None
        self.reply_text = None
        enc = self.enc = OpusEncoder(SR_PLEX)

        async for msg in ws:
            if msg.type == WSMsgType.TEXT:
                await self._on_event(ws, msg.data)
            elif msg.type == WSMsgType.BINARY:
                data = msg.data
                if len(data) < AUDIO_HEADER.size:
                    continue
                rid = AUDIO_HEADER.unpack_from(data)[0]
                a24 = np.frombuffer(data, "<i2", offset=AUDIO_HEADER.size).astype(np.float32) / 32768.0
                if rid == self.barged_rid:            # the page stops playback on a barge
                    continue
                self.playhead.on_audio(rid, len(a24))  # before anything can be tagged with it
                if rid != BACKCHANNEL_ID:
                    if rid != self.reply_rid:
                        self.reply_rid, self.reply_samples = rid, 0
                        self.reply_t0 = time.perf_counter()
                    self.reply_samples += len(a24)
                    self.reply_t1 = time.perf_counter()
                payload = enc.encode(a24)
                if payload:
                    self.encoded_bytes += len(payload)
                    if DUMP_DIR:
                        try:
                            with open(os.path.join(DUMP_DIR, f"reply-{rid}.ogg"), "ab") as f:
                                f.write(payload)
                        except OSError as e:
                            log(f"dump failed: {e!r}")
                    await self.ws.send_bytes(b"\x01" + payload)

    async def _on_event(self, ws, text: str):
        try:
            ev = json.loads(text)
        except (json.JSONDecodeError, TypeError):
            return
        t = ev.get("type")
        if t == "ready":
            self.sr_ears = int(ev.get("sr") or 16000)
            self.tyger_ready = True
            log(f"ready hop_ms={ev.get('hop_ms')} sr={self.sr_ears} mouth={ev.get('mouth')} "
                f"voice={ev.get('voice')} max_session_s={ev.get('max_session_s')}")
            if not ev.get("mouth"):
                log("WARNING: tyger reports no MOUTH: it will hear but never speak")
        elif t == "endpoint":
            log(f"endpoint by={ev.get('by')} turn_s={ev.get('turn_s')} transcript={ev.get('transcript')!r}")
        elif t == "partial":
            pass                                        # the user's words growing; endpoint carries them whole
        elif t == "reply":
            # Fires per token with the CUMULATIVE text (conversation.py:390): keep the latest and log it
            # once, at turn_done, so the log stays readable and still carries the reply for the evidence.
            self.reply_text = ev.get("text") or self.reply_text
        elif t == "backchannel":
            log(f"backchannel text={ev.get('text')!r}")
        elif t == "barge":
            log(f"barge yield={ev.get('yield')}: playback stopped, dropping the rest of reply {self.reply_rid}")
            self.barged_rid = self.reply_rid
            self.playhead.stop()
            if self.enc is not None:
                self.enc.reset()                   # nothing more of that reply goes out (step 4 drains it properly)
        elif t == "turn_done":
            tail = await self._flush_audio()
            wall = (self.reply_t1 - self.reply_t0) if self.reply_t0 and self.reply_t1 else 0.0
            log(f"turn_done barged={ev.get('barged')} reply=rid {self.reply_rid} "
                f"samples={self.reply_samples} ({self.reply_samples / SR_PLEX:.2f} s of speech) "
                f"arrived_over={wall:.2f} s wall tail_frame={len(tail)} B encoded_total={self.encoded_bytes} B")
            if wall and self.reply_samples:
                log(f"reply pacing: {self.reply_samples / SR_PLEX / wall:.2f}x real time "
                    f"(>1: tyger generated faster than it plays; the door's 1.2 s gate tracks arrival, not playback)")
            if self.reply_text:
                log(f"reply text={self.reply_text!r}")
        elif t == "error":
            log(f"tyger error {ev.get('error')}")
        elif t == "busy":
            log("tyger busy: no free conversation slot")
        elif t == "session_end":
            log(f"session_end reason={ev.get('reason')}")
        elif t == "state":
            # One per hop (~3/s): log the transitions, and a heartbeat line so a soak
            # can tell "quiet" from "dead".
            self.state_events += 1
            st = ev.get("state")
            if st != self.last_state or self.state_events % 50 == 0:
                self.last_state = st
                log(f"state {st} (event {self.state_events}) "
                    f"{json.dumps({k: v for k, v in ev.items() if k not in ('type', 'state')})[:160]}")
        elif t in ("bc_cue", "voice", "threshold", "links", "task_done", "backchannel_done"):
            log(f"{t} {json.dumps({k: v for k, v in ev.items() if k != 'type'})[:200]}")

    # ---- leg C: the plex role ----
    async def uplink(self):
        """plexpipe's 0x01 Ogg -> PCM -> the EARS rate -> 20 ms mic blocks, tagged with the playhead."""
        dec = OpusDecoder(SR_PLEX)
        rs = StreamingAudioResampler(SR_PLEX, self.sr_ears)
        pending = np.zeros(0, np.float32)
        pending_t0 = 0.0

        async for msg in self.ws:
            if msg.type == WSMsgType.TEXT:
                continue                                # plexpipe sends no text on this leg
            if msg.type != WSMsgType.BINARY or not msg.data:
                continue
            data = msg.data
            if data[0] != 0x01:
                continue                                # only the audio tag exists on this leg
            pcm = dec.decode(data[1:])
            if pcm is None:
                continue
            x = rs.process(pcm)                         # rate comes from `ready`; set before any audio
            if not x.size:
                continue
            now = time.perf_counter()
            if pending.size == 0:
                pending_t0 = now - x.size / self.sr_ears   # captured over the interval ending now
            pending = np.concatenate([pending, x])
            while pending.size >= BLOCK:
                blk = pending[:BLOCK]
                pending = pending[BLOCK:]
                t = pending_t0
                pending_t0 = t + BLOCK / self.sr_ears
                await self.send_mic(blk, t)

    async def send_mic(self, blk: np.ndarray, t_capture: float):
        if not self.tyger_ready or self.tyger is None or self.tyger.closed:
            self.dropped_blocks += 1
            return
        rid, at = self.playhead.tag(t_capture)
        try:
            await self.tyger.send_bytes(MIC_HEADER.pack(rid, at) + to_pcm16(blk).tobytes())
        except (ConnectionError, RuntimeError):
            self.tyger_ready = False
            return
        self.blocks += 1
        self.mic_bytes += BLOCK * 2
        if self.blocks % MIC_LOG_EVERY == 0:
            log(f"mic blocks={self.blocks} bytes={self.mic_bytes} tag=r{rid}@{at} "
                f"dropped={self.dropped_blocks}")


async def plex_chat(request: web.Request) -> web.WebSocketResponse:
    global SESSIONS
    ws = web.WebSocketResponse(max_msg_size=0)
    await ws.prepare(request)
    text_prompt = request.query.get("text_prompt", "")
    voice_prompt = request.query.get("voice_prompt", "")
    log(f"plex dial from {request.remote}; voice_prompt={voice_prompt!r}; text_prompt ignored "
        f"({len(text_prompt)} chars: tyger answers with its own character prompt)")
    # The handshake plexpipe waits for (server.py:165-171). Sent at once, so its uplink pump starts and this
    # leg never looks dead to it while tyger is still being dialled.
    await ws.send_bytes(b"\x00")

    SESSIONS += 1
    session = PlexSession(ws, request.app["http"], voice_prompt)
    tasks = [asyncio.create_task(session.uplink()), asyncio.create_task(session.tyger_manager())]
    try:
        await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    finally:
        session.stop.set()
        for t in tasks:
            t.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        if session.tyger is not None and not session.tyger.closed:
            await session.tyger.close()
        SESSIONS -= 1
        log(f"plex session closed: mic blocks={session.blocks} bytes={session.mic_bytes} "
            f"dropped={session.dropped_blocks} reply rid={session.reply_rid} "
            f"samples={session.reply_samples} encoded={session.encoded_bytes} B")
    return ws


_health: dict = {"at": 0.0, "ok": False, "detail": "not probed"}


async def tyger_health(http: aiohttp.ClientSession) -> dict:
    """Is there a tyger behind this gateway? Cached for HEALTH_TTL_S: the ExecStartPre gate polls it."""
    now = time.monotonic()
    if now - _health["at"] < HEALTH_TTL_S:
        return _health
    try:
        async with http.get(TYGER_VOICES, timeout=aiohttp.ClientTimeout(total=2.0)) as r:
            body = await r.read()
            ok = r.status == 200
            detail = f"http {r.status}, {len(body)} B"
    except Exception as e:                                          # noqa: BLE001 - any error is "not ready"
        ok, detail = False, repr(e)
    _health.update(at=now, ok=ok, detail=detail)
    return _health


async def health(request: web.Request) -> web.Response:
    h = await tyger_health(request.app["http"])
    return web.json_response(
        {"ok": h["ok"], "tyger": TYGER_WS, "voices": TYGER_VOICES, "detail": h["detail"],
         "sessions": SESSIONS, "token": "set" if TYGER_SECRET else "unset"},
        status=200 if h["ok"] else 503)


async def main():
    app = web.Application()
    app.add_routes([web.get("/api/chat", plex_chat), web.get("/health", health)])
    async with aiohttp.ClientSession() as http:
        app["http"] = http
        runner = web.AppRunner(app, access_log=None)
        await runner.setup()
        site = web.TCPSite(runner, "0.0.0.0", PORT)
        await site.start()
        log(f"listening on :{PORT} (tyger={TYGER_WS})")
        try:
            await asyncio.Future()
        finally:
            await runner.cleanup()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass