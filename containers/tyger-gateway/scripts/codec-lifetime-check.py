#!/usr/bin/env python3
"""codec-lifetime-check -- run session-shaped lifecycles through the gateway's own codec layer.

Run inside the gateway container, from anywhere on the ai box (the container's cwd is /app, so
`import plexio` finds the image's copy):

    podman exec -i systemd-tyger-gateway python3 - \
        < containers/tyger-gateway/scripts/codec-lifetime-check.py

Exit 0 = every session survived. Exit 1 = a session killed the codec (the 2026-11-14 defect).

The mechanism it guards (sphn 0.1.12, measured in the live container): a sphn `OpusStreamReader`
decodes one Ogg stream; feed it a page from a DIFFERENT Ogg stream and its background decoder thread
dies -- the next read returns nothing, the read after that raises ValueError('sending on a closed
channel'), for the rest of the process's life. A fresh `OpusStreamWriter` starts a fresh Ogg stream
(new serial, new header). So replacing the writer mid-connection kills the reader on the other end.

The gateway used to build an encoder and a decoder per door session (dropped at teardown), and
OpusEncoder.reset() -- the barge path -- replaced its writer. Each replacement restarted the Ogg
stream the gateway sends to plexpipe, so plexpipe's live reader died the moment the owner barged (his
own voice), and the cascade took the whole chain down: 358 'plex streaming' lines, one per second, for
6.5 minutes, cleared only by a process restart.

The fix: one process-scoped pair (plexio.codec_pair()) for the process's whole life; reset() clears
the buffered tail and keeps the writer, so the Ogg stream never restarts. The check drives that: one
long-lived reader is fed the encoder's pages across N session-shaped lifecycles, with a barge
(enc.reset()) inside each. Old code restarts the stream at the first barge and the reader dies; the
fix keeps one stream and the reader lives.
"""
from __future__ import annotations

import gc
import sys
import time

import numpy as np

import plexio

SR = 24000
FRAME = 1920
N = 3                      # N >= 3 session-shaped lifecycles (GATE2 acceptance / PLAN-V03-step2.md)


def blk() -> np.ndarray:
    return (np.random.randn(FRAME) * 0.05).astype(np.float32)


def session_codecs():
    """The (decoder, encoder) a session uses, plus whether they are per-session (the old shape).

    With the fix, plexio exposes a process-scoped pair and per_session is False -- the caller has
    nothing to drop and the Ogg stream never restarts. Without it, the caller builds per-session
    objects and drops them at teardown, exactly as the old gateway did.
    """
    pair = getattr(plexio, "codec_pair", None)
    if pair is not None:
        p = pair()
        return p.dec, p.enc, False
    return plexio.OpusDecoder(SR), plexio.OpusEncoder(SR), True


def teardown(prev: "list | None") -> None:
    """End a session: drop its codec objects (the old shape). A shared pair drops nothing."""
    if prev and prev[2]:
        prev[0] = prev[1] = None
        print("  previous session teardown: codec objects dropped (a new Ogg stream next session)")
        gc.collect()


def main() -> int:
    version = getattr(getattr(plexio, "sphn", None), "__version__", "?")
    print(f"codec-lifetime-check: N={N} sessions, sphn {version}")
    if hasattr(plexio, "codec_pair"):
        if plexio.codec_pair() is not plexio.codec_pair():
            print("FAIL: codec_pair() is not process-scoped (returns a new pair each call)")
            return 1
        print("  codec pair: process-scoped (plexio.codec_pair()), created once, never dropped")
    else:
        print("  codec pair: NONE -- plexio builds codecs per session (the defect's shape)")

    # The peer's reader (plexpipe's side of the gateway's reply audio): one reader for the whole run.
    peer = plexio.OpusDecoder(SR)
    prev = None
    failures = 0
    samples = 0

    def feed(enc) -> None:
        nonlocal failures, samples
        for payload in enc.encode(blk()):
            try:
                out = peer.decode(payload)
                samples += 0 if out is None else len(out)
            except ValueError as e:
                failures += 1
                print(f"    peer reader RAISED {e!r}")
            time.sleep(0.02)

    for i in range(1, N + 1):
        dec, enc, per = session_codecs()
        print(f"session {i}: streaming reply audio to the peer")
        feed(enc)                          # the reply's first 80 ms frames
        enc.reset()                        # a barge: the old code replaces the writer here
        feed(enc)                          # the reply (or the next turn) continues

        teardown(prev)                     # the PREVIOUS session ends, this session already live
        prev = [dec, enc, per]

    teardown(prev)
    print(f"peer reader decoded {samples} samples across {N} sessions, {failures} failure(s)")
    if failures:
        print(f"FAIL: the peer reader died -- {failures} read(s) raised across {N} sessions")
        return 1
    if samples == 0:
        print("FAIL: the peer reader decoded no audio (the Ogg stream never reached it)")
        return 1
    print(f"PASS: {N} sessions on one Ogg stream, peer reader alive")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
