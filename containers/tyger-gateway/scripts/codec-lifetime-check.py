#!/usr/bin/env python3
"""codec-lifetime-check -- run session-shaped lifecycles through the gateway's own codec layer.

Run inside the gateway container, from anywhere on the ai box (the container's cwd is /app, so
`import plexio` finds the image's copy):

    podman exec -i systemd-tyger-gateway python3 - \
        < containers/tyger-gateway/scripts/codec-lifetime-check.py

Exit 0 = every session survived. Exit 1 = a barge restarted the Ogg stream and killed the peer reader
(the 2026-11-14 defect).

The mechanism it guards (sphn 0.1.12, measured in the live container): each OpusStreamReader/Writer has
its own Ogg stream. Dropping a codec object is harmless, but a reader dies for good -- next read
silent, the one after raises ValueError('sending on a closed channel') -- when it is fed a page from a
SECOND stream, or when it starts mid-stream without the header. Building a new OpusStreamWriter starts
a new stream.

The gateway used to build a new writer on a barge (OpusEncoder.reset replaced the writer) and on every
tyger reconnect (a new OpusEncoder in tyger_loop). Each replacement restarted the Ogg stream the
gateway sends plexpipe, so plexpipe's live reader died the moment the owner barged (his own voice), and
the cascade took the chain down: 358 'plex streaming' lines, one per second, for 6.5 minutes, cleared
only by a process restart.

The fix: one codec pair per door session, born with the session's streams; within the session the
writer is never replaced -- a barge clears the buffered tail (reset) and keeps the writer. The check
drives that: each session makes a writer and a peer reader, streams some reply frames, barges (reset),
and streams again. Old code restarts the stream at the barge and the peer reader dies; the fix keeps
one stream and the peer reader lives.
"""
from __future__ import annotations

import time

import numpy as np

import plexio

SR = 24000
FRAME = 1920
N = 3                      # N >= 3 session-shaped lifecycles (GATE2 acceptance / PLAN-V03-step2.md)


def blk() -> np.ndarray:
    return (np.random.randn(FRAME) * 0.05).astype(np.float32)


def main() -> int:
    version = getattr(getattr(plexio, "sphn", None), "__version__", "?")
    print(f"codec-lifetime-check: N={N} sessions, sphn {version}")
    failures = 0
    samples = 0

    for i in range(1, N + 1):
        enc = plexio.OpusEncoder(SR)       # this session's writer (born with this session's stream)
        peer = plexio.OpusDecoder(SR)      # the peer's reader for this session (plexpipe's side)

        def feed() -> None:
            nonlocal failures, samples
            for _ in range(4):                 # enough frames for header+tags+audio to flow
                for payload in enc.encode(blk()):
                    try:
                        out = peer.decode(payload)
                        samples += 0 if out is None else len(out)
                    except ValueError as e:
                        failures += 1
                        print(f"    peer reader RAISED {e!r}")
                    time.sleep(0.02)

        print(f"session {i}: streaming reply audio to the peer")
        feed()                             # the reply, header first
        enc.reset()                        # a barge: old code builds a NEW writer (new Ogg stream)
        feed()                             # the reply continues -- must stay on the SAME stream

    print(f"peer decoded {samples} samples across {N} sessions, {failures} failure(s)")
    if failures:
        print("FAIL: the peer reader died -- a replaced writer restarted the Ogg stream")
        return 1
    if samples == 0:
        print("FAIL: the peer reader decoded no audio")
        return 1
    print(f"PASS: {N} sessions, the peer reader survived every barge on one stream")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
