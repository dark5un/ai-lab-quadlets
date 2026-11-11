# max-call — Google Meet real-time-avatar joiner (spike)

Headless Google Meet joiner machinery for a real-time avatar on a box with
**no root and no video devices**: Playwright Chromium guest-join observer
(CDP network interception, fake media devices) + aiortc media session sending
synthetic avatar tracks (640×480 animated VP8 test pattern + 440 Hz Opus tone).

**Status: machinery validated; live-room join unverified (no meeting link).**
See [spike-report.md](spike-report.md) for evidence and gaps.

## Layout

```
apps/max-call/
  src/maxcall/
    tracks.py        synthetic avatar tracks (TestPatternVideoTrack, SineAudioTrack)
    probe_meet.py    Meet/alkaline/STUN endpoint reachability probes (no creds sent)
    observer.py      Playwright Chromium + CDP interception (redacted) + guest join
    meet_session.py  native alkaline-style aiortc leg (EXPERIMENTAL, token required)
    local_p2p.py     aiortc <-> aiortc loopback validation (PASS)
    browser_p2p.py   Chromium <-> aiortc interop validation (PASS)
    join.py          CLI orchestrator (--url for a live join)
  artifacts/         screenshots + validation_results.json (gitignore-worthy, local only)
  run.sh             env wrapper (venv/browsers/libs live in scratch, NOT in repo)
  pyproject.toml     deps (venv deliberately created outside the repo)
```

## Setup (all outside the repo dir)

```bash
E=/home/px/.hermes/cache/scratch
uv venv --python 3.12 $E/max-call-venv
VIRTUAL_ENV=$E/max-call-venv uv pip install aiortc playwright numpy
PLAYWRIGHT_BROWSERS_PATH=$E/pw-browsers $E/max-call-venv/bin/playwright install chromium
# rootless lib bootstrap for chrome-headless-shell (Arch, no pacman perms):
bash $E/max-call/fetch_pwlibs2.sh   # extracts atk/at-spi/alsa/libX* .so into $E/pwlibs/lib
```

## Run

```bash
cd apps/max-call
bash run.sh src/maxcall/join.py                # offline validation suite
bash run.sh src/maxcall/join.py --url https://meet.google.com/abc-defg-hij --hold 60
```

## Hard rules

* Never store or log Google credentials; observer redacts any cookie/auth/token
  material (lengths only) before anything is written to disk.
* `alkaline.google.com` is **NXDOMAIN** as of 2026-11 — the legacy native
  callout gateway endpoints are not reachable by name from here; the
  `meet.google.com/o/webrtc-inbound-call` path answers (404/400 = route lives
  behind auth). Do not build against alkaline until a token flow proves it.
