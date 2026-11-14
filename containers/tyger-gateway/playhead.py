"""The page's playback clock, without a page: what the user was hearing at each mic block.

Copied from the tyger fork's scripts/stack/page.py (`PageSim`: `tag`, `on_audio`, `_report`, `stop`), which is
the vendor's own model of what static/index.html does on EARS's WebSocket. Behaviour is kept identical --
reply audio "plays" on the wall clock as it arrives, back to back, LEAD_IN_S after it arrives when nothing is
queued; each mic block is tagged with the reply id and the reply sample (at 24 kHz) that was playing; when a
reply's queue drains the page reports `played:<id>:<samples>`; a barge stops playback. Backchannel audio
(id 0) plays but is never tagged and never reported.

Two deliberate limits, both stated in PLAN-V03-step2.md §4 rather than hidden here:

* this is a GATEWAY-SIDE clock, not MAX Out's CoreAudio clock. It is what the playhead tag is worth while
  maxaudiod runs --gate (the uplink is zero for 1.2 s after any real downlink, so tyger never hears Max and
  there is no echo to reject). Step 4 (I-26) replaces it with the CoreAudio clock; nothing before that may
  claim full duplex.
* `on_audio` is called when the reply audio is handed to the plex leg, i.e. slightly BEFORE plexpipe has
  forwarded it and BEFORE maxaudiod has played it. The error is one encode + one network hop, and it is the
  same direction of error the browser page has (it queues on arrival).
"""
from __future__ import annotations

import asyncio
import time

WIRE_SR = 24000                  # the reply's rate, as page.py:62 counts it
LEAD_IN_S = 0.04                 # page.py:29 (app/ears/playback.py)
BACKCHANNEL_ID = 0               # playback.py:30: played by the page, never tagged
KEEP_S = 5.0                     # page.py:80: schedule entries older than this are dropped


class Playhead:
    """`report(rid, samples)` is awaited when a reply has played out (PageSim._report)."""

    def __init__(self, report):
        self.report = report
        self.sched: list[tuple[int, float, float, int]] = []   # (rid, t0, t1, its first sample)
        self.next_play = 0.0
        self.queued: dict[int, int] = {}
        self.last_id = 0
        self.ends: dict[int, float] = {}
        self.sent: dict[int, int] = {}                          # rid -> 24 kHz samples handed over
        self.tasks: set[asyncio.Task] = set()

    def tag(self, t: float) -> tuple[int, int]:
        """(reply id, its sample at 24 kHz) playing at time t; (the last id, -1) when nothing is."""
        for rid, t0, t1, first in reversed(self.sched):
            if t0 <= t < t1:
                return rid, first + int((t - t0) * WIRE_SR)
        return self.last_id, -1

    def on_audio(self, rid: int, n: int) -> None:
        """`n` samples (at 24 kHz) of reply/backchannel `rid` were handed to the plex leg."""
        now = time.perf_counter()
        if self.next_play < now:
            self.next_play = now + LEAD_IN_S
        t0 = self.next_play
        self.next_play = t1 = t0 + n / WIRE_SR
        self.sent[rid] = self.sent.get(rid, 0) + n
        if rid != BACKCHANNEL_ID:
            first = self.queued.get(rid, 0)
            self.queued[rid] = first + n
            self.last_id = rid
            self.sched = [c for c in self.sched if c[2] > now - KEEP_S] + [(rid, t0, t1, first)]
            self.ends[rid] = t1
            task = asyncio.ensure_future(self._report(rid, t1))
            self.tasks.add(task)
            task.add_done_callback(self.tasks.discard)

    async def _report(self, rid: int, end: float) -> None:
        await asyncio.sleep(max(0.0, end - time.perf_counter()))
        if self.next_play <= end + 1e-6:            # nothing queued after it: the reply has played out
            await self.report(rid, self.queued[rid])

    def stop(self) -> None:
        """A barge: playback stops, nothing more is tagged or reported."""
        self.sched = []
        self.next_play = 0.0
        for task in list(self.tasks):
            task.cancel()

    def reset(self) -> None:
        """A new conversation on the far side: ids start again at 1."""
        self.stop()
        self.queued = {}
        self.ends = {}
        self.sent = {}
        self.last_id = 0