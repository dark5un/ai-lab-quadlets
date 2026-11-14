#!/usr/bin/env python3
"""frame-integrity-check -- every whole frame the gateway encodes must decode on the peer, in full.

Run inside the gateway container (the container's cwd is /app, so `import plexio` finds the image's copy):

    podman exec -i systemd-tyger-gateway python3 - \
        < containers/tyger-gateway/scripts/frame-integrity-check.py

Exit 0 = the peer decoded every sample. Exit 1 = the reply was short.

The defect it guards (sphn 0.1.12, measured live 2026-11-14): OpusStreamWriter emits its Ogg
OpusHead and OpusTags pages on its FIRST read_bytes() calls -- before any audio. Reading this stream
with one read_bytes() per frame therefore spent the first two reads on headers and left the LAST two
audio frames unread, so every reply reached the door exactly 160 ms short (152 frames in -> 150 out;
the Mac played 288000 of a reply's 291840 samples). The encoder now emits the header pages with 0
samples and reads on for the frame's audio, so the peer decodes all N frames.
"""
from __future__ import annotations

import time

import numpy as np
import sphn

import plexio

SR = 24000
FRAME = 1920
N = 152                    # a long reply: 12.16 s, the shape the live loss was measured on


def frame(k: int) -> np.ndarray:
    t = np.arange(FRAME) / SR
    return (0.5 * np.sin(2 * np.pi * (200 + 20 * k) * t)).astype(np.float32)


def main() -> int:
    version = getattr(getattr(plexio, "sphn", None), "__version__", "?")
    print(f"frame-integrity-check: N={N} frames, sphn {version}")
    enc = plexio.OpusEncoder(SR)
    peer = sphn.OpusStreamReader(SR)     # the door's reader: one append + one read per message

    header_pages = 0
    audio_pages = 0
    samples = 0
    for k in range(N):
        for n, payload in enc.encode(frame(k)):
            if n == 0:
                header_pages += 1
            else:
                audio_pages += 1
            peer.append_bytes(payload)
            pcm = peer.read_pcm()
            if pcm is None or np.size(pcm) == 0:
                time.sleep(0.005)
                pcm = peer.read_pcm()
            samples += 0 if pcm is None else int(np.size(pcm))

    expect = N * FRAME
    print(f"header pages={header_pages} audio pages={audio_pages} peer decoded={samples} "
          f"samples ({samples/FRAME:.1f} frames) of {expect} ({N} frames)")
    if header_pages != 2:
        print("FAIL: expected exactly 2 header pages (OpusHead, OpusTags)")
        return 1
    if audio_pages != N:
        print(f"FAIL: {audio_pages} audio pages for {N} frames")
        return 1
    if samples != expect:
        print(f"FAIL: the reply is short by {(expect - samples)/FRAME:.1f} frames "
              f"({(expect - samples)/SR*1000:.0f} ms)")
        return 1
    print("PASS: the peer decoded every frame; the reply is not short")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
