"""The plex leg's codec: sphn's Opus streams, 24 kHz mono, both ways.

Framing mirrors containers/plexpipe/server.py:153-155,185-187,194-210, which is the live-proven python mirror
of duplex-bus fdb_personaplex.py: the caller prepends the one-byte tag (`0x01`) itself, and sphn only ever
carries the Ogg/Opus payload.

`sphn==0.1.12` is pinned in requirements.txt for the reason plexpipe pins it: 0.2.x redesigned these classes
(OpusStreamWriter lost `read_bytes`, the reader lost the append-side API), and 0.1.12 is what plexpipe and the
personaplex fork run against.
"""
from __future__ import annotations

import numpy as np
import sphn


class OpusDecoder:
    """`0x01` payload bytes in, float32 PCM at `rate` out, or None while the decoder wants more input.

    Never drop or replace this while any other codec object is alive in the process (see the
    lifetime rule at the foot of this file). There is deliberately no `reset()` here: the only way to
    reset a sphn reader is to build a new one, and building a new one DROPS the old -- which kills
    every live reader in the process.
    """

    def __init__(self, rate: int = 24000):
        self.rate = rate
        self._reader = sphn.OpusStreamReader(rate)

    def decode(self, payload: bytes) -> np.ndarray | None:
        self._reader.append_bytes(payload)
        pcm = self._reader.read_pcm()
        if pcm is None:
            return None
        if pcm.ndim > 1:
            pcm = pcm.reshape(-1)
        return pcm.astype(np.float32, copy=False)


FRAME = 1920   # 80 ms at 24 kHz: the size plexpipe feeds sphn (plexpipe server.py:63). sphn's
               # OpusStreamWriter.append_pcm only accepts whole frames -- 120/240/480/960/1920/2880
               # samples -- and tyger hands over reply audio in arbitrary chunk lengths (observed live:
               # a 11510-sample chunk raised ValueError, killing the leg mid-reply). So the encoder
               # buffers and emits whole frames, exactly as plexpipe's up_pump does.


class OpusEncoder:
    """float32 PCM at `rate` in, whole `0x01` payloads out (possibly none while a frame is filling).

    Returns a LIST: one item per 80 ms frame. The caller must send them ONE PER MESSAGE and paced at
    real time -- plexpipe drains its Reader with a single read_pcm per incoming message
    (plexpipe server.py:194-196), and sphn 0.1.12's reader only produces PCM when it gets a moment
    between append_bytes and read_pcm. Measured live 2026-11-14: 210 messages appended and read
    back-to-back yielded 0 samples; the same bytes read after a pause yielded all 172800 (7.2 s). A
    burst therefore loses most of a reply (personaplex, which emits one frame per 80 ms, loses none).
    """

    def __init__(self, rate: int = 24000, frame: int = FRAME):
        self.rate = rate
        self.frame = frame
        self._writer = sphn.OpusStreamWriter(rate)
        self._buf = np.zeros(0, np.float32)

    def encode(self, pcm: np.ndarray) -> list[bytes]:
        self._buf = np.concatenate([self._buf, np.asarray(pcm, dtype=np.float32)])
        out: list[bytes] = []
        while self._buf.size >= self.frame:
            frame = self._buf[:self.frame]
            self._buf = self._buf[self.frame:]
            self._writer.append_pcm(frame)
            b = self._writer.read_bytes()
            if b:
                out.append(b)
        return out

    def flush(self) -> list[bytes]:
        """End the current turn's audio cleanly: pad the partial frame with silence and emit it.

        Called at a turn boundary (turn_done). Without it the tail samples of one reply sit in the
        buffer and are emitted at the head of the NEXT reply's audio.
        """
        if not self._buf.size:
            return []
        pad = (-self._buf.size) % self.frame
        if pad:
            self._buf = np.concatenate([self._buf, np.zeros(pad, np.float32)])
        return self.encode(np.zeros(0, np.float32))

    def reset(self) -> None:
        """A barge or a new conversation: drop the buffered tail, KEEP the writer object.

        Replacing the writer here is a codec-object DROP, and under sphn 0.1.12 a single drop kills
        every live reader in the process -- that is what broke the chain live on 2026-11-14. Only the
        partial frame is discarded; the Opus stream continues on the same writer.
        """
        self._buf = np.zeros(0, np.float32)

    @property
    def pending(self) -> int:
        """Samples held back waiting for a whole frame (0 between turns)."""
        return int(self._buf.size)


# ---- the lifetime rule, and the one pair this process uses --------------------------------------
#
# sphn 0.1.12 keeps its codec work on a channel shared by the whole process: the moment ANY codec
# object is garbage-collected, every reader that was already alive goes dead -- its next use silently
# returns nothing, the use after that raises ValueError('sending on a closed channel'), for the rest
# of the process's life. (Receipt: scripts/codec-lifetime-check.py.) So this process creates exactly
# ONE encoder and ONE decoder and keeps them for its whole life. A barge or a new tyger conversation
# clears the encoder's buffer (OpusEncoder.reset); it never replaces the object. Two door sessions at
# once would share this pair; the door serves one at a time (plexpipe), which is why one shared pair
# is correct here and why the object is process-scoped rather than held per session.


class CodecPair:
    """The one encoder/decoder pair this process uses, for the process's whole life."""

    def __init__(self, rate: int = 24000, frame: int = FRAME):
        self.rate = rate
        self.dec = OpusDecoder(rate)
        self.enc = OpusEncoder(rate, frame)


_pair: "CodecPair | None" = None


def codec_pair(rate: int = 24000) -> CodecPair:
    """The process-scoped pair: created once, returned to every caller, never dropped."""
    global _pair
    if _pair is None:
        _pair = CodecPair(rate)
    return _pair
