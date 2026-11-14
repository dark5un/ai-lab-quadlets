#!/usr/bin/env python3
"""turn-timeline.py <outdir> -- print the five stamps and the deltas of PLAN-latency.md.

Reads the artifacts turn-timeline.sh left in <outdir>: t0.txt (this Mac's clock), skew.txt (box minus
Mac), tyger.log and gateway.log (box logs, `podman logs -t`), play-events.log (maxaudiod's DAC
instants, this Mac's clock). Box stamps are moved onto the Mac's clock so every delta joins two
machines that agree on time, not on NTP.
"""
import datetime
import os
import re
import sys

TS = re.compile(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{1,9})Z")


def box_epoch(s):
    """The RFC3339 stamp at the head of a `podman logs -t` line, as epoch seconds (box clock)."""
    m = TS.search(s)
    if not m:
        return None
    dt = datetime.datetime.strptime(m.group(1)[:26], "%Y-%m-%dT%H:%M:%S.%f")
    return dt.replace(tzinfo=datetime.timezone.utc).timestamp()


def hhmm(x):
    return datetime.datetime.fromtimestamp(x).strftime("%H:%M:%S.%f")[:-3]


def read(path):
    try:
        return open(path, errors="replace").read().splitlines()
    except OSError:
        return []


def main():
    out = sys.argv[1]
    t0_file = os.path.join(out, "t0.txt")
    if not os.path.exists(t0_file):
        sys.exit(f"turn-timeline.py: no {t0_file}: did the turn run?")
    t0 = float(open(t0_file).read().strip())
    skew = float(open(os.path.join(out, "skew.txt")).read().strip()) if os.path.exists(
        os.path.join(out, "skew.txt")) else 0.0

    tyger = read(os.path.join(out, "tyger.log"))
    gateway = read(os.path.join(out, "gateway.log"))

    # t1: tyger's endpoint, the first one at/after the utterance end (-1 s for the device buffer).
    endpoint_lines = [(box_epoch(l), l) for l in tyger if "endpoint by=" in l]
    t1 = None
    t1_line = ""
    for ts, line in endpoint_lines:
        if ts is not None and ts - skew >= t0 - 1.0:
            t1, t1_line = ts - skew, line
            break

    # t2: the mouth's first audio for that turn (the log line's own stamp IS the instant).
    t2 = None
    t2_line = ""
    if t1 is not None:
        for line in tyger:
            if "onset: first-text" in line and "first-audio" in line:
                ts = box_epoch(line)
                if ts is not None and ts - skew >= t1 - 0.5:
                    t2, t2_line = ts - skew, line
                    break

    # t3: the gateway's first frame of a real reply out to the door (rid 0 is a backchannel).
    t3 = None
    t3_line = ""
    rid = None
    gw_reply = re.compile(r"reply (\d+): first frame out after (\d+) ms from its first audio")
    for line in gateway:
        m = gw_reply.search(line)
        if m and int(m.group(1)) >= 1:
            ts = box_epoch(line)
            if ts is not None and ts - skew >= (t1 if t1 is not None else t0) - 0.5:
                t3, t3_line, rid = ts - skew, line, int(m.group(1))
                break

    # t4: the Mac's first playback of that reply, from the DAC clock (this Mac's clock, no skew).
    t4 = None
    for line in read(os.path.join(out, "play-events.log")):
        p = line.split()
        if len(p) == 3 and p[1] == "first-play":
            r = int(p[2].split("=")[1])
            w = float(p[0])
            if r >= 1 and (rid is None or r == rid) and w >= (t3 if t3 is not None else t0) - 0.5:
                t4 = w
                break

    def row(name, what, t):
        if t is None:
            print(f"  {name:<4} {'--':>14}  {'':<10}  {what}")
        else:
            print(f"  {name:<4} {hhmm(t):>14}  {t:>12.3f}  ({(t - t0) * 1000:>+7.0f} ms)  {what}")

    print(f"\nturn timeline  ({out})")
    print(f"  clock skew box-mac = {skew:+.3f} s (box stamps moved onto this Mac's clock)")
    print(f"  {'stamp':<4} {'local':>14}  {'epoch':>12}")
    row("t0", "harness stopped writing the utterance into MAX Out (this Mac)", t0)
    row("t1", "tyger decided the turn ended (`endpoint`)", t1)
    row("t2", "tyger's first reply audio (`onset: first-audio`)", t2)
    row("t3", f"the gateway's first frame of reply {rid} left for the door", t3)
    row("t4", "the Mac's first sample of the reply at MAX Mic's DAC", t4)

    print("\n  deltas")
    if t1 is not None:
        print(f"  t1-t0  {(t1 - t0) * 1000:>7.0f} ms   waiting for tyger to decide the turn ended")
    if t1 is not None and t2 is not None:
        print(f"  t2-t1  {(t2 - t1) * 1000:>7.0f} ms   tyger's model, to its first audio")
    if t2 is not None and t3 is not None:
        print(f"  t3-t2  {(t3 - t2) * 1000:>7.0f} ms   the gateway, first audio to first frame out")
    if t3 is not None and t4 is not None:
        print(f"  t4-t3  {(t4 - t3) * 1000:>7.0f} ms   the door + the device, frame out to playback")
    if t4 is not None:
        print(f"  FELT   {(t4 - t0) * 1000:>7.0f} ms   t4-t0: utterance end to the reply being heard")
    else:
        print("  FELT        n/a      no playback stamp: check the reply and PLAY_EVENTS")

    # diagnostics: anything that would make a stamp wrong
    print(f"\n  endpoint lines in the window: {len(endpoint_lines)}")
    if t1_line:
        print(f"    t1 line: {t1_line.split('INFO')[-1].strip()[:110]}")
    if t2_line:
        print(f"    t2 line: {t2_line.split('INFO')[-1].strip()[:110]}")
    if t3_line:
        print(f"    t3 line: {t3_line.split('] ')[-1].strip()[:110]}")
    play = [l for l in read(os.path.join(out, "play-events.log")) if "first-play" in l and float(l.split()[0]) >= t0 - 1]
    print(f"  play events at/after t0: {play if play else 'none'}")


if __name__ == "__main__":
    main()
