#!/usr/bin/env python3
"""tag-pairing-check -- pair the Mac's playhead tags with mic blocks, through the gateway's own code.

Run inside the gateway container (the container's cwd is /app, so `import server` finds the image's
copy):

    podman exec -i systemd-tyger-gateway python3 - \
        < containers/tyger-gateway/scripts/tag-pairing-check.py

What it guards (V03 step 4, I-26): maxaudiod measures, per captured MAX Out block, which reply sample
was at MAX Mic's DAC. That tag travels beside the audio through plexpipe, which resamples 48 -> 24 kHz
and reframes to 80 ms Opus, so the block that carries capture position p reaches the gateway one frame
later than the tag that describes it. The gateway therefore pairs TAG to BLOCK by capture position
(`server.PlexSession.tag_for`), not by arrival order. This drives that function with a synthetic Mac:
a continuous capture counter, a continuous 20 ms block stream, and a reply whose sample count rises at
24000 samples/s from a known capture position.

It is a regression guard for the pairing arithmetic, not Gate evidence (the gate is a real barge on the
real chain).
"""
from __future__ import annotations

import server as gw

RID = 1                     # the reply being played
PLAY_FROM_CAP = 48000       # it starts reaching the DAC 1 s into the capture stream
CAP = gw.CAP_SR             # 48000 capture positions/s
BLOCK48 = gw.TAG_BLOCK48    # 960 capture positions per 20 ms mic block
SR24 = gw.SR_PLEX           # 24000: the reply's own rate


def reply_sample_at(cap: int) -> int:
    """The reply sample at the DAC when capture position `cap` was sampled (-1: nothing playing)."""
    if cap < PLAY_FROM_CAP:
        return -1
    return (cap - PLAY_FROM_CAP) * SR24 // CAP


def new_session() -> tuple[gw.PlexSession, list]:
    """A session with dummy legs (nothing here touches the socket) and its tag log."""
    sent: list = []
    return gw.PlexSession(ws=None, http=None, voice_prompt=""), sent   # type: ignore[arg-type]


def feed(s: gw.PlexSession, fed: set, upto_stream_pos: int, first_cap: int) -> None:
    """Give the session every tag the Mac would have sent by mic stream position `upto_stream_pos`."""
    for k in range(upto_stream_pos // BLOCK48 + 1):
        cap = first_cap + k * BLOCK48
        if cap in fed:
            continue
        fed.add(cap)
        s.on_tag(gw.TAG.pack(RID, reply_sample_at(cap), cap + 0))


def check_pipeline(first_cap: int, latency_blocks: int, blocks: int = 300) -> tuple[int, int]:
    """Blocks follow tags `latency_blocks` behind (the plexpipe + Opus pipeline). Returns (checked, worst)."""
    s, _ = new_session()
    fed: set = set()
    worst = 0
    for k in range(blocks):
        pos = k * BLOCK48
        feed(s, fed, pos + latency_blocks * BLOCK48, first_cap)   # tags run ahead of the blocks
        rid, at, src = s.tag_for(pos, t_capture=0.0)
        truth = reply_sample_at(first_cap + pos)
        if truth < 0:
            if at != -1 or rid != RID:
                raise AssertionError(f"block {k}: idle should be r{RID}@-1, got r{rid}@{at}")
            continue
        if src != "mac":
            raise AssertionError(f"block {k}: paired by {src!r}, expected the Mac's tag")
        err = abs(at - truth)
        worst = max(worst, err)
        if err > 2:                                                # interpolation + one block: exact
            raise AssertionError(f"block {k}: tag r{rid}@{at} but the reply was at {truth} ({err} samples off)")
    return blocks, worst


def check_no_tags_falls_back() -> None:
    """Before any tag (a Mac without step 4, or personaplex behind the door) the model answers."""
    s, _ = new_session()
    rid, at, src = s.tag_for(0, t_capture=0.0)
    if src != "model" or not isinstance(at, int):
        raise AssertionError(f"no tags: expected the wall-clock model, got {src!r} r{rid}@{at}")


def check_lag_is_reported() -> None:
    """Tags that fall behind the audio are counted, never silently paired as if current."""
    s, _ = new_session()
    fed: set = set()
    for k in range(60):
        pos = k * BLOCK48
        feed(s, fed, pos - 8 * BLOCK48, 0)          # the Mac's tag stream stalled 8 blocks back
        s.tag_for(pos, t_capture=0.0)
    if s.tag_lagged == 0:
        raise AssertionError("a stalled tag stream was not reported as lagged")
    print(f"  lag reported on {s.tag_lagged} blocks (hits={s.tag_hits}, old={s.tag_old})")


def check_offset_anchor() -> None:
    """A Mac counter that does not start at 0 (a reconnect) is still anchored to the right block."""
    checked, worst = check_pipeline(first_cap=5_000_000 + 3 * BLOCK48, latency_blocks=6, blocks=120)
    print(f"  reconnected Mac counter: {checked} blocks paired, worst {worst} sample(s) off")


def check_capture_restart() -> None:
    """A Mac that restarts its capture stream mid-session is re-aligned, not paired with nonsense.

    This is the 2026-11-14 failure: stale frames from the previous door session put a 16 s position at
    the head of the new session's tag stream, the anchor was taken from it, and every block after that
    was 'lagged' by 12 s (hits=0). A backwards jump in positions now re-anchors the alignment.
    """
    s, _ = new_session()
    fed: set = set()
    for k in range(100):                                     # stream 1: positions 0..100 blocks
        pos = k * BLOCK48
        feed(s, fed, pos + 4 * BLOCK48, 0)
        s.tag_for(pos, t_capture=0.0)
    fed2: set = set()
    paired = 0
    for k in range(100, 160):                                # stream 2 restarts at 0 mid-session
        pos = k * BLOCK48
        feed(s, fed2, (k - 100 + 4) * BLOCK48, 0)
        rid, at, src = s.tag_for(pos, t_capture=0.0)
        paired += src == "mac"
    if paired < 50:
        raise AssertionError(f"after a capture-stream restart only {paired}/60 blocks paired by the Mac's tag")
    print(f"  capture stream restarted mid-session: re-anchored, {paired}/60 blocks paired")


def main() -> int:
    print(f"tag-pairing-check: tag={gw.TAG.size} B, block={BLOCK48} capture positions ({BLOCK48 / CAP * 1000:.0f} ms)")
    checked, worst = check_pipeline(first_cap=0, latency_blocks=8)
    print(f"  clean pipeline, tags 8 blocks ahead: {checked} blocks paired, worst {worst} sample(s) off")
    check_no_tags_falls_back()
    print("  no tags -> the wall-clock model answers (fallback intact)")
    check_lag_is_reported()
    check_offset_anchor()
    check_capture_restart()
    print("tag-pairing: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())