"""tyger-gateway -- the `plex` upstream that plexpipe dials, speaking tyger's /ws.

plexpipe is unchanged. Per door session it dials PLEX_URL and expects the personaplex "plex" role
(containers/plexpipe/server.py:148-244): WS /api/chat?text_prompt=&voice_prompt=, a one-byte b"\x00"
handshake, then 0x01+Ogg/Opus at 24 kHz both ways. This process serves that role and carries the audio to a
tyger-s2s EARS WebSocket instead of personaplex. Contracts: WIRE-TABLES-v03.md, legs C and D.

  leg C (plex, plexpipe <-> here)   0x01 + Ogg/Opus 24 kHz mono, both ways   (plexpipe server.py:187,194-210)
                                    0x03 + <iii rid, reply sample at 24 kHz, capture position at 48 kHz>
                                    = the Mac's measured playhead tag (V03 step 4, I-26), one per uplink
                                    block, relayed by plexpipe; and a TEXT frame `played:<rid>:<samples>`
                     downlink       0x03 + utf8 JSON {"t":"reply","rid":N} before a reply's first frame and
                                    {"t":"drain","rid":N} on a barge -- plexpipe passes both to the Mac
  leg D (tyger /ws)  uplink         [int32 rid][int32 agent sample at 24 kHz, -1] + int16 PCM 16 kHz
                                    (app/ears/playback.py:16-18,31,45-52; 20 ms blocks = 648 B, page.py:16)
                     downlink       [int32 rid, 0 = backchannel] + int16 PCM 24 kHz (playback.py:31-32,40-42)
                     commands       played:<rid>:<samples>, reset, voice:<name>, set:<attr>:<value>

The playhead is MEASURED (step 4): maxaudiod reads PortAudio's device clock and states which reply sample
was at MAX Mic's DAC when each MAX Out block was captured; this process pairs that tag with the block by
capture position and sends it as tyger's mic-block tag. `playhead.py` (a gateway-side wall clock) stays only
as the fallback for when no tag arrives, and its `played:` reports stop once the Mac reports its own.

What is deliberately NOT here: secret/pages posture (V05: this process CAN carry a token, it does not set
one) and any voice-identity work.

Privacy: tyger itself logs no transcripts (app/ears/conversation.py:27). This gateway logs them, because Gate 1's
evidence is "MAX Out's transcript matches the reply text in the gateway log" (PLAN-V03-step2.md §2).

Codec lifetime: one encoder/decoder pair per door session, created once and never replaced within the
session. A barge and a tyger reconnect clear the encoder's buffered tail (plexio.OpusEncoder.reset)
instead of building a new writer. sphn 0.1.12 gives each codec object its own Ogg stream: a reader dies
for good if it is fed a second stream or if it starts mid-stream without the header, so replacing the
writer inside a session restarted the stream the gateway sends plexpipe and plexpipe's live reader
died -- the storm of 2026-11-14. See plexio.py's Ogg-stream rule and scripts/codec-lifetime-check.py.
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
from collections import deque

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
# V03 step 4 (I-26): the playhead tag the Mac sends beside each uplink block, relayed by plexpipe as
# 0x03: reply id, the reply sample at 24 kHz that was at the DAC when the block was captured (-1: none),
# and the capture position of that block at 48 kHz (what pairs the tag with its audio, §8 of the plan).
TAG = struct.Struct("<iii")
CAP_SR = 48000                         # the tag's position unit (MAX Out capture rate)
TAG_BLOCK48 = BLOCK * CAP_SR // 16000   # 960: one 20 ms mic block, in capture positions
TAGS_KEEP_S = 30.0                     # tags older than this are dropped. Bigger than the audio path's
                                       # own buffering (measured 3.5 s behind at a session start), because
                                       # the tag for a block arrives BEFORE the block does: the window has
                                       # to cover the pipeline's latency, or the pairing has nothing left
                                       # to pair against.

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
        self.enc = OpusEncoder(SR_PLEX)   # one writer per session: never replaced within it
        self.dl: asyncio.Queue = asyncio.Queue()      # (rid, payload, samples) waiting to be paced out
        self.sent_frames = 0
        self.sent_samples = 0
        self.sent_t0 = 0.0
        self.sent_t1 = 0.0
        self.playhead = Playhead(self._report_played)
        # The Mac's measured playhead (V03 step 4): tags by capture position, and what it says was played.
        self.tags = deque()                           # (capture position at 48 kHz, rid, sample at 24 kHz)
        self.tag_offset = None                        # mic stream position -> capture position
        self.tag_seen = False
        self.mic_pos48 = 0                            # this session's mic stream position, 48 kHz units
        self.tag_hits = self.tag_lagged = self.tag_old = 0
        self.plex_msgs = 0                            # 0x01 messages decoded (an uplink rate probe)
        self.mac_reports = 0                          # `played:` reports relayed from the Mac
        self.last_tag_log = 0.0

    def _drop_queued(self) -> int:
        """Throw away frames not yet sent (a barge, or a new tyger conversation)."""
        n = 0
        while True:
            try:
                self.dl.get_nowait()
                n += 1
            except asyncio.QueueEmpty:
                return n

    async def _flush_audio(self) -> int:
        """Queue the tail of the current reply as a whole frame (a turn boundary; OpusEncoder.flush)."""
        if self.enc is None:
            return 0
        n = 0
        for payload in self.enc.flush():
            self.dl.put_nowait((self.reply_rid, payload, self.enc.frame))
            n += 1
        return n

    # ---- leg D: the client side of tyger's /ws ----
    async def _report_played(self, rid: int, samples: int) -> None:
        """The gateway-side model says a reply has played out -- the FALLBACK once the Mac reports.

        `playhead.Playhead` schedules from when audio was handed to the plex leg, so it over-reports by
        the device + meeting loop. With step 4 in place the Mac's own `played:` report is the truth, and
        this model stops speaking for it (a premature report ends tyger's turn early).
        """
        if self.tag_seen or self.mac_reports:
            # The Mac owns the clock (its tags are on the wire), so this model must not speak for it:
            # measured 2026-11-14, it reported played:1:19200 while the Mac played 13440, 100 ms earlier,
            # ending tyger's turn before the reply had finished.
            return
        await self._send_played(rid, samples, "model")

    async def _send_played(self, rid: int, samples: int, source: str) -> None:
        ws = self.tyger
        if ws is None or ws.closed:
            return
        try:
            await ws.send_str(f"played:{rid}:{samples}")
            log(f"played:{rid}:{samples} sent (source={source})")
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
        self.enc.reset()                              # a new conversation: clear the buffer, keep the writer
        self._drop_queued()                           # a new conversation: stale audio is not this reply

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
                if rid != BACKCHANNEL_ID:
                    if rid != self.reply_rid:
                        self.reply_rid, self.reply_samples = rid, 0
                        self.reply_t0 = time.perf_counter()
                    self.reply_samples += len(a24)
                    self.reply_t1 = time.perf_counter()
                # NOT sent here: tyger hands a whole reply over in a burst (measured 11-15x real
                # time), and plexpipe drains one frame per incoming message. Queue the frames and
                # let downlink() pace them; the playhead is advanced there, when they really go out.
                for payload in self.enc.encode(a24):
                    self.dl.put_nowait((rid, payload, self.enc.frame))

    async def downlink(self):
        """Send the reply's audio to plexpipe: ONE 80 ms frame per message, paced at real time.

        This is the fix for the truncation found live on 2026-11-14: a burst made plexpipe's single
        read_pcm per message race sphn's decoder and lose ~5/6 of the reply (maxaudiod played 1.8 s
        of 9.44 s; personaplex, which emits one frame per 80 ms, lost nothing behind the same door).
        """
        next_send = 0.0
        frames = 0
        announced = None
        while not self.stop.is_set():
            rid, payload, samples = await self.dl.get()
            if rid == self.barged_rid:
                continue
            if self.ws.closed:
                return
            now = time.perf_counter()
            if next_send > now:
                await asyncio.sleep(next_send - now)
                now = time.perf_counter()
            if rid != announced:
                # Tell the Mac which reply it is about to hear (V03 step 4): its playhead tag names that
                # id, and backchannel audio (0) is announced too so it is never counted into a reply.
                announced = rid
                try:
                    await self.ws.send_bytes(b"\x03" + json.dumps({"t": "reply", "rid": rid}).encode())
                except (ConnectionError, RuntimeError):
                    return
            self.playhead.on_audio(rid, samples)      # schedule as it goes out, not as it arrived
            try:
                await self.ws.send_bytes(b"\x01" + payload)
            except (ConnectionError, RuntimeError):
                return
            if DUMP_DIR:                              # exactly what this leg put on the wire
                try:
                    with open(os.path.join(DUMP_DIR, f"reply-{rid}.ogg"), "ab") as f:
                        f.write(payload)
                except OSError as e:
                    log(f"dump failed: {e!r}")
            if frames == 0:
                self.sent_t0 = now
            frames += 1
            self.sent_frames += 1
            self.sent_samples += samples
            self.sent_t1 = now
            self.encoded_bytes += len(payload)
            next_send = max(next_send, now) + samples / SR_PLEX
            if frames % 62 == 0:                      # ~5 s of audio
                log(f"downlink: {self.sent_samples / SR_PLEX:.1f} s sent to the door, "
                    f"queue {self.dl.qsize()} frames")

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
            dropped = self._drop_queued()            # nothing more of that reply goes out
            if dropped:
                log(f"barge: {dropped} unsent frames dropped")
            if self.enc is not None:
                self.enc.reset()                     # the buffer, never the writer (plexio.py: Ogg-stream rule)
            await self._send_drain(self.reply_rid)   # and the Mac flushes what it already holds
        elif t == "turn_done":
            tail = await self._flush_audio()
            wall = (self.reply_t1 - self.reply_t0) if self.reply_t0 and self.reply_t1 else 0.0
            log(f"turn_done barged={ev.get('barged')} reply=rid {self.reply_rid} "
                f"samples={self.reply_samples} ({self.reply_samples / SR_PLEX:.2f} s of speech) "
                f"arrived_over={wall:.2f} s wall tail_frames={tail} queue={self.dl.qsize()} "
                f"encoded_total={self.encoded_bytes} B")
            if wall and self.reply_samples:
                log(f"reply arrived at {self.reply_samples / SR_PLEX / wall:.1f}x real time; "
                    f"the downlink pump trims that to 1.0x for plexpipe (see downlink())")
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

    # ---- the Mac's measured playhead (V03 step 4, I-26) ----
    async def _send_drain(self, rid: int) -> None:
        """A barge: tell the Mac to flush MAX Mic now, so the reply stops within one device buffer."""
        try:
            await self.ws.send_bytes(b"\x03" + json.dumps({"t": "drain", "rid": rid}).encode())
            log(f"drain sent for rid {rid}")
        except (ConnectionError, RuntimeError):
            pass

    def on_tag(self, payload: bytes) -> None:
        """One playhead tag from the Mac, relayed by plexpipe as 0x03 (12 bytes, little-endian)."""
        if len(payload) < TAG.size:
            return
        rid, at, cap = TAG.unpack_from(payload)
        if self.tags and cap < self.tags[-1][0] - CAP_SR:
            # The capture position jumped backwards: the Mac started a NEW capture stream (a door
            # reconnect) while this plex session lives on. Its positions are unrelated to the old
            # stream's, so the alignment is re-anchored on the new one instead of pairing nonsense.
            log(f"playhead: the Mac's capture stream restarted (pos {self.tags[-1][0]} -> {cap}): "
                f"re-aligning")
            self.tags.clear()
            self.tag_offset = None
        self.tags.append((cap, rid, at))
        while self.tags and self.tags[0][0] < cap - int(TAGS_KEEP_S * CAP_SR):
            self.tags.popleft()
        if not self.tag_seen:
            self.tag_seen = True
            log(f"playhead from the Mac: tag=r{rid}@{at} pos={cap} "
                f"(measured at MAX Mic's DAC, not modelled)")

    async def _on_plex_text(self, text: str) -> None:
        """A text frame from plexpipe: the Mac's `played:<rid>:<samples>` report, as tyger's page sends."""
        if not text.startswith("played:"):
            log(f"plex text ignored: {text[:60]!r}")
            return
        try:
            _, rid_s, n_s = text.split(":", 2)
            rid, samples = int(rid_s), int(n_s)
        except ValueError:
            log(f"bad played report from the Mac: {text[:60]!r}")
            return
        self.mac_reports += 1
        await self._send_played(rid, samples, "mac")

    def tag_for(self, pos: int, t_capture: float) -> tuple[int, int, str]:
        """(reply id, its sample at 24 kHz, source) for the mic block at stream position `pos`.

        The Mac measures the tag; this attaches it to the right block. Position, not arrival order, is
        the pairing key: the audio is resampled (48 -> 24 k) and reframed (80 ms Opus), so the block that
        carries capture position p reaches this leg one Opus frame after the tag that describes it. The
        offset between this session's mic stream and the Mac's capture counter is anchored on the first
        tag of the session (usually 0: both start with the same audio) and, inside a block, the reply
        sample is interpolated at the reply's own rate. Without any tag (a Mac build before step 4, or
        personaplex behind the door) the wall-clock `playhead` model answers, as it did in step 2.
        """
        if not self.tags:
            rid, at = self.playhead.tag(t_capture)
            return rid, at, "model"
        if self.tag_offset is None:
            self.tag_offset = self.tags[0][0] - pos      # the session's first block <-> its first tag
            log(f"playhead alignment: offset={self.tag_offset} capture positions "
                f"(mic stream position {pos} <-> capture position {self.tags[0][0]})")
        target = pos + self.tag_offset
        hit = None
        for cap, rid, at in reversed(self.tags):
            if cap <= target:
                hit = (cap, rid, at)
                break
        if hit is None:                                  # older than every tag held: use the oldest
            cap, rid, at = self.tags[0]
            self.tag_old += 1
            return rid, at, "old"
        cap, rid, at = hit
        age = target - cap
        at += int(age * SR_PLEX / CAP_SR)                # within the block, at the reply's own rate
        if age >= TAG_BLOCK48:                           # the tag stream fell behind the audio: say so
            self.tag_lagged += 1
            now = time.perf_counter()
            if now - self.last_tag_log > 5.0:
                self.last_tag_log = now
                log(f"playhead tags lag the audio by {age / CAP_SR * 1000:.0f} ms "
                    f"(hits={self.tag_hits} lagged={self.tag_lagged} old={self.tag_old})")
            return rid, at, "lagged"
        self.tag_hits += 1
        return rid, at, "mac"

    # ---- leg C: the plex role ----
    async def uplink(self):
        """plexpipe's 0x01 Ogg -> PCM -> the EARS rate -> 20 ms mic blocks, tagged with the playhead."""
        dec = OpusDecoder(SR_PLEX)
        rs = StreamingAudioResampler(SR_PLEX, self.sr_ears)
        pending = np.zeros(0, np.float32)
        pending_t0 = 0.0

        async for msg in self.ws:
            if msg.type == WSMsgType.TEXT:
                await self._on_plex_text(msg.data)       # the Mac's played:<rid>:<samples>, relayed
                continue
            if msg.type != WSMsgType.BINARY or not msg.data:
                continue
            data = msg.data
            if data[0] == 0x03:
                self.on_tag(data[1:])                    # the Mac's playhead tag for one block
                continue
            if data[0] != 0x01:
                continue                                # nothing else exists on this leg
            self.plex_msgs += 1
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
                pos = self.mic_pos48                  # the stream position the tag is paired against
                self.mic_pos48 += TAG_BLOCK48
                await self.send_mic(blk, t, pos)

    async def send_mic(self, blk: np.ndarray, t_capture: float, pos: int):
        if not self.tyger_ready or self.tyger is None or self.tyger.closed:
            self.dropped_blocks += 1
            return
        rid, at, src = self.tag_for(pos, t_capture)
        try:
            await self.tyger.send_bytes(MIC_HEADER.pack(rid, at) + to_pcm16(blk).tobytes())
        except (ConnectionError, RuntimeError):
            self.tyger_ready = False
            return
        self.blocks += 1
        self.mic_bytes += BLOCK * 2
        if self.blocks % MIC_LOG_EVERY == 0:
            tags = f"oldest={self.tags[0][0]} newest={self.tags[-1][0]}" if self.tags else "none"
            log(f"mic blocks={self.blocks} bytes={self.mic_bytes} tag=r{rid}@{at} src={src} "
                f"pos={pos} offset={self.tag_offset} {tags} msgs={self.plex_msgs} dropped={self.dropped_blocks} "
                f"tags: hits={self.tag_hits} lagged={self.tag_lagged} old={self.tag_old}")


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
    tasks = [asyncio.create_task(coro, name=name) for name, coro in
             (("uplink", session.uplink()), ("tyger", session.tyger_manager()),
              ("downlink", session.downlink()))]
    try:
        done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for t in done:
            exc = t.exception()
            log(f"session task '{t.get_name()}' finished{'' if exc is None else f': {exc!r}'}")
    finally:
        session.stop.set()
        for t in tasks:
            t.cancel()
        results = await asyncio.gather(*tasks, return_exceptions=True)
        for t, r in zip(tasks, results):
            if isinstance(r, BaseException) and not isinstance(r, asyncio.CancelledError):
                log(f"session task '{t.get_name()}' raised: {r!r}")
        if session.tyger is not None and not session.tyger.closed:
            await session.tyger.close()
        SESSIONS -= 1
        log(f"plex session closed: mic blocks={session.blocks} bytes={session.mic_bytes} "
            f"dropped={session.dropped_blocks} reply rid={session.reply_rid} "
            f"arrived={session.reply_samples} sent={session.sent_samples} samples "
            f"({session.sent_samples / SR_PLEX:.2f} s on the wire) encoded={session.encoded_bytes} B "
            f"tags: hits={session.tag_hits} lagged={session.tag_lagged} old={session.tag_old} "
            f"mac_played={session.mac_reports}")
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