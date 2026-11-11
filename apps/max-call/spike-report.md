# max-call spike report — Google Meet real-time avatar joiner

Generated: 2026-11-11T22:55:27Z (all measurements from real runs on this host, not estimates)
Host: Arch Linux (kernel 7.2.14-arch1-1), no root, no `/dev/video*`; `/dev/snd` present but unused — all media is synthetic.

## Scope

Scaffold at `apps/max-call/` implementing the meetbot-pattern joiner:
Playwright-Chromium guest-join observer with CDP network interception
(headless, `--use-fake-ui-for-media-stream --use-fake-device-for-media-stream`)
+ aiortc `RTCPeerConnection` driven with synthetic avatar tracks
(640×480 animated VP8 test pattern, 440 Hz Opus tone), receiving far-end
tracks and counting frames/sec. **No live meeting link was provided**
(`--url` unset), so per the task fallback the machinery was validated
end-to-end against self-hosted WebRTC instead, with Meet signaling
reachability probed separately.

## 1. Environment (venv deliberately OUTSIDE the repo dir)

- venv: `uv venv --python 3.12 /home/px/.hermes/cache/scratch/max-call-venv`
  (uv 0.13.6; aiortc 1.16.0, playwright 1.65.0, PyAV 19.0.2, numpy 2.5.4)
- Chromium (playwright chromium-headless-shell 158.0.8127.18) at
  `scratch/pw-browsers/`, deps bootstrapped rootlessly from Arch packages
  (atk, at-spi2-*, alsa-lib, libxcomposite/damage/fixes/randr, libxkbcommon,
  libxi, libxtst) extracted to `scratch/pwlibs/lib` + `LD_LIBRARY_PATH` —
  no root needed. Wrapper: `run.sh`.

## 2. Meet signaling / ICE endpoint reachability (from this host)

Result: **9 of 13 reachable.**

| check | target | verdict | evidence |
|---|---|---|---|
| meet landing | https://meet.google.com/ | PASS | 200 |
| alkaline root (legacy Duo gw) | https://alkaline.google.com/ | FAIL | URLError: <urlopen error [Errno -2] Name or service not known> |
| callout pair token (signaling auth) | https://alkaline.google.com/v1/sessions:allocateWebRtcCalloutPairToken | FAIL | URLError: <urlopen error [Errno -2] Name or service not known> |
| ice server config | https://alkaline.google.com/v1/config/iceServerConfig/meet | FAIL | URLError: <urlopen error [Errno -2] Name or service not known> |
| webrtc-inbound-call on meet host | https://meet.google.com/o/webrtc-inbound-call | PASS | 404 |
| webrtc-inbound-call (ws upgrade via https) | https://alkaline.google.com/o/webrtc-inbound-call | FAIL | URLError: <urlopen error [Errno -2] Name or service not known> |
| webrtc-inbound-call WS upgrade | wss://meet.google.com/o/webrtc-inbound-call | PASS | HTTP/1.1 400 Bad Request |
| stun:stun.l.google.com:19302 |  | PASS | 0x101 |
| stun:alt1.stun.l.google.com:19302 |  | PASS | 0x101 |
| stun:alt2.stun.l.google.com:19302 |  | PASS | 0x101 |
| stun:alt3.stun.l.google.com:19302 |  | PASS | 0x101 |
| stun:alt4.stun.l.google.com:19302 |  | PASS | 0x101 |
| stun:alt5.stun.l.google.com:19302 |  | PASS | 0x101 |

Findings that matter for the join design:

- **`alkaline.google.com` is NXDOMAIN** (DNS, not a block): the legacy
  Google-telephony gateway host that the classic "allocateWebRtcCalloutPairToken"
  callout flow was documented against **no longer resolves publicly**. Any
  browserless native leg must be re-derived from live traffic (see §5).
- **`meet.google.com/o/webrtc-inbound-call` answers on the Meet host**
  (HTTP 404 without auth context; raw WS Upgrade → `HTTP/1.1 400 Bad Request`)
  — the route family is live and gated, i.e. a pairing token minted by an
  authenticated context is the actual gate, not network reachability.
- Outbound UDP 19302 STUN works to all six Google STUN endpoints (correct
  names are `alt1..alt5.stun.l.google.com`, *not* `alt*.stun.google.com`).
  Meet's real ICE-TCP/SSLTCP media servers are provisioned per-call and could
  not be enumerated without a live room.
- No credentials were sent to any endpoint (empty GET/POST bodies, no cookies).

## 3. aiortc <-> aiortc loopback P2P (track plumbing proof) — PASS

Two in-process `RTCPeerConnection`s, one sending the avatar tracks:

- ICE: `completed` / `completed` — DTLS/SRTP: `connected` / `connected` (negotiated SRTP_AEAD_AES_256_GCM)
- Video: **299 frames received in 10s = 29.9 fps**, decoded shapes [640, 480, 'yuv420p'] (640×480 yuv420p VP8)
- Audio: **494 frames = 49.4 fps** (Opus 48 kHz, 20 ms decode steps ≈ 50/s)
- Raw decoded video bandwidth ≈ 220 Mbit/s, audio 9.1 Mbit/s

Engineering notes captured in `src/maxcall/tracks.py`: aiortc's Opus encoder
asserts **packed s16** stereo; `time_base` must be a `Fraction`; pacing must
use the fixed-pts-grid idiom or the sender burst-emits late frames.

## 4. Chromium <-> aiortc interop (the join-path's strongest offline proof) — PASS

Headless Chromium (`--use-fake-*-media-stream`) with a page `RTCPeerConnection`
negotiated against an aiortc `RTCPeerConnection` over loopback, stdlib HTTP
signaling (`browser_p2p.py`):

- `getUserMedia` fake devices on this device-less box: `['audio:Fake Default Audio Input', 'video:fake_device_0']`
- Browser WebRTC: ICE `connected`, connection `connected`
- Browser inbound from our aiortc avatar: video **148 frames decoded**, 300055 bytes (≈ 240 kbit/s), 306 pkts; audio 72081 bytes / 247 pkts Opus
- aiortc inbound from the browser's fake camera/mic: {'video': 99, 'audio': 248} frames in 10 s (9.9 fps video — matches Chromium's ~10 fps fake_device_0)
- Screenshot of the observer page: `artifacts/interop_browser_page.png`
- Pitfall proven: `RTCPeerConnection` must be **constructed inside the asyncio
  loop thread** it will run on (aiortc captures the loop at construction —
  cross-thread creation silently kills senders with
  "Future attached to a different loop").

## 5. Playwright observer against real meet.google.com — PARTIAL PASS (as far as possible without a room)

`join.py` (no `--url`) ran the observer against the live Meet web app:

- CDP request interception fires for the signaling patterns:
  ["https://alkaline.google.com/v1/sessions:allocateWebRtcCalloutPairToken", "https://meet.google.com/o/webrtc-inbound-call"]
- Guest-code URL rendered headlessly: **"You can't join this video call Return to home screen Submit feedback Your meeting is safe No one can join a meeting unle..."**
  — i.e. Meet's own app UI ("You can't join this video call") with the
  camera/mic consent prompt handled automatically by the fake-UI flag
- Screenshots: `artifacts/meet_landing.png`, `artifacts/meet_guest_screen.png`
- Event log: `artifacts/observer_events.json`; all captured headers/tokens are
  redacted to shape+length before persistence.

Native leg implementation (`meet_session.py`): builds the pair-token WS client
(`wss://…/o/webrtc-inbound-call`) + ICE config fetch + a real aiortc session
with the avatar tracks. Its handshake framing is a **best-effort reconstruction**
and is wired for the moment a token is observable; the alkaline hostnames it
was modeled on no longer resolve (§2), so the flow must be re-confirmed from
captured traffic on a live join before being trusted.

## 6. What remains UNVERIFIED without a live meeting link

1. **Actual guest join + lobby/admission flow** on a real room (`Observer.join_meet`
   selectors are the meetbot-pattern ones — `join-button` testid / "Join now"
   role — but untested against a live prejoin screen).
2. **Live WebRTC signaling token extraction** (what headers/body the current
   Meet client uses for `o/webrtc-inbound-call` or its successor — needs one
   real join's network capture).
3. **The native browserless leg end-to-end**: ICE against Meet's per-call
   media servers (UDP/TCP/SSLTCP on 443), SRTP interop with Google's SFU,
   simulcast/transport-cc expectations, and whether aiortc's VP8/Opus profile
   is accepted by the Meet SFU at all.
4. 60-second live hold stats (ICE state transitions, bitrate, far-end track
   counts) — the logging/sampling code exists in `join.py --url ... --hold 60`
   and produced these same stats for the offline legs.

Deliberate non-goals: no credentials stored/typed anywhere; nothing outside
`apps/max-call/` + scratch dirs; no git commits.

## Reproduce

```bash
cd apps/max-call
bash run.sh src/maxcall/probe_meet.py      # §2
bash run.sh src/maxcall/local_p2p.py       # §3
bash run.sh src/maxcall/browser_p2p.py 10  # §4
bash run.sh src/maxcall/join.py            # §2+3+4+5 in one pass
bash run.sh src/maxcall/join.py --url https://meet.google.com/xxx-xxxx-xxx --hold 60  # closes the §6 gaps
```
