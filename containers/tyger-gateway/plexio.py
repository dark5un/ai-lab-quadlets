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
    """`0x01` payload bytes in, float32 PCM at `rate` out, or None while the decoder wants more input."""

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

    def reset(self) -> None:
        self._reader = sphn.OpusStreamReader(self.rate)


FRAME = 1920   # 80 ms at 24 kHz: the size plexpipe feeds sphn (plexpipe server.py:63). sphn's
               # OpusStreamWriter.append_pcm only accepts whole frames -- 120/240/480/960/1920/2880
               # samples -- and tyger hands over reply audio in arbitrary chunk lengths (observed live:
               # a 11510-sample chunk raised ValueError, killing the leg mid-reply). So the encoder
               # buffers and emits whole frames, exactly as plexpipe's up_pump does.


class OpusEncoder:
    """float32 PCM at `rate` in, `0x01` payload bytes out (possibly empty while the frame is filling)."""

    def __init__(self, rate: int = 24000, frame: int = FRAME):
        self.rate = rate
        self.frame = frame
        self._writer = sphn.OpusStreamWriter(rate)
        self._buf = np.zeros(0, np.float32)

    def encode(self, pcm: np.ndarray) -> bytes:
        self._buf = np.concatenate([self._buf, np.asarray(pcm, dtype=np.float32)])
        out = bytearray()
        while self._buf.size >= self.frame:
            frame = self._buf[:self.frame]
            self._buf = self._buf[self.frame:]
            self._writer.append_pcm(frame)
            b = self._writer.read_bytes()
            if b:
                out += b
        return bytes(out)

    def flush(self) -> bytes:
        """End the current turn's audio cleanly: pad the partial frame with silence and send it.

        Called at a turn boundary (turn_done / barge). Without it the tail samples of one reply sit in
        the buffer and are emitted at the head of the NEXT reply's audio.
        """
        if not self._buf.size:
            return b""
        pad = (-self._buf.size) % self.frame
        if pad:
            self._buf = np.concatenate([self._buf, np.zeros(pad, np.float32)])
        return self.encode(np.zeros(0, np.float32))

    def reset(self) -> None:
        self._writer = sphn.OpusStreamWriter(self.rate)
        self._buf = np.zeros(0, np.float32)

    @property
    def pending(self) -> int:
        """Samples held back waiting for a whole frame (0 between turns)."""
        return int(self._buf.size)