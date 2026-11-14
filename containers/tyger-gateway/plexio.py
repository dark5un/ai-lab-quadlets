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


class OpusEncoder:
    """float32 PCM at `rate` in, `0x01` payload bytes out (possibly empty while the frame is filling)."""

    def __init__(self, rate: int = 24000):
        self.rate = rate
        self._writer = sphn.OpusStreamWriter(rate)

    def encode(self, pcm: np.ndarray) -> bytes:
        self._writer.append_pcm(np.asarray(pcm, dtype=np.float32))
        return self._writer.read_bytes()

    def reset(self) -> None:
        self._writer = sphn.OpusStreamWriter(self.rate)