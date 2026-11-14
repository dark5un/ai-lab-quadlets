# tyger-gateway

The `plex` upstream that **plexpipe** dials, speaking **tyger-s2s**'s `/ws` instead of personaplex.

plexpipe, the tailnet door (`tailscale serve :8457`), `maxaudiod` and the HAL devices do not change. This
process slots in behind plexpipe and answers the role personaplex used to answer
(`PLAN-V03-step2.md`, `WIRE-TABLES-v03.md`).

```
MAX Mic -> maxaudiod --gate -> :8457 -> plexpipe --leg C--> tyger-gateway --leg D--> tyger-v1 /ws (5090)
                                        <-leg C--                     <-leg D--
```

## Wire

| leg | direction | frames |
|---|---|---|
| C, plex (plexpipe ⇄ here) | in | WS `/api/chat?text_prompt=&voice_prompt=` → `b"\x00"` handshake, then `0x01`+Ogg/Opus **24 kHz** |
| C | out | `0x01`+Ogg/Opus **24 kHz** (reply + backchannel audio) |
| D, tyger (`/ws`) | out | `[int32 rid][int32 agent sample at 24 kHz, -1]` + int16 PCM **16 kHz**, 20 ms blocks (648 B) |
| D | in | `[int32 rid, 0 = backchannel]` + int16 PCM **24 kHz** |
| D | text | `ready`, `endpoint`, `partial`, `reply`, `backchannel`, `barge`, `turn_done`, `error`, `session_end`, … |
| D | text out | `played:<rid>:<samples>` — without it tyger ends the turn on its own guess + 2 s |

Every row is cited to `file:line` in `WIRE-TABLES-v03.md`. `resample.py` is the fork's
`app/runtime/audio.py` copied verbatim (24 → `ready.sr`); `playhead.py` is the fork's `scripts/stack/page.py`
`PageSim` clock.

## Endpoints

- `GET /api/chat?text_prompt=&voice_prompt=` — the plex role. `voice_prompt` is logged and ignored; tyger
  answers with its own character prompt (`voices.character: max` in `config/local.yaml`).
- `GET /health` — **200 only when a real tyger answers** (`GET <TYGER_VOICES_URL>`); 503 otherwise. This is
  what plexpipe's `ExecStartPre` gate polls, so a stopped tyger makes plexpipe refuse to start instead of
  starting and redialling in a storm.

## Env

| var | default | |
|---|---|---|
| `GATEWAY_PORT` | `8994` | |
| `TYGER_URL` | `ws://tyger-v1:7860/ws` | |
| `TYGER_VOICES_URL` | `http://tyger-v1:7860/voices` | the health probe |
| `TYGER_API_SECRET` | *unset* | set ⇒ an HS256 token is signed per connect (`aud: tyger`, `exp` 60 s, fresh `jti`). Step 2 does **not** set it: tyger stays open and loopback-only (V05 owns the posture) |

## Why the downlink is paced at real time

tyger hands a whole reply over in a **burst** (measured 11–15× real time: 9.44 s of speech in 0.74 s).
plexpipe drains its `sphn` Reader with **one `read_pcm()` per incoming message** (`plexpipe server.py:194-196`),
and sphn 0.1.12 only yields PCM if the decoder gets a moment between `append_bytes()` and `read_pcm()`.
Measured: 210 messages appended and read back-to-back gave **0 samples**; the same bytes read after a
pause gave all **172,800** (7.2 s). So a burst loses most of a reply — maxaudiod played 1.8 s of a 9.44 s
reply and the recording was 1.9 s of speech then exact digital silence.

Behind the same door, **personaplex loses nothing** (maxaudiod's playback tally: 560 chunks = 44.5 s,
contiguous) because it emits one 80 ms frame per 80 ms. `downlink()` therefore queues the frames and
sends **one 80 ms frame per message, paced at 1.0× real time**, exactly like the brain it replaces. The
playhead is advanced there — when a frame really goes out — so its tags describe what the door has.

## Honest limits (in the plan, not discovered later)

- The playhead is a **gateway-side** clock, not MAX Out's CoreAudio clock (I-26 → step 4). It is true while
  `maxaudiod --gate` zeroes the uplink for 1.2 s after any real downlink, so tyger never hears Max and there
  is no echo to reject. Nothing here claims full duplex.
- A `barge` stops this gateway's playhead and drops the rest of that reply. A real drain of what is already
  buffered downstream is step 4.
- `0x02` caption frames are not produced (tyger has structured `reply`/`partial` JSON; v1 logs it instead).
- No secrets, no auth on this port: loopback publish + the stack network only.

## Build and run (ai box)

```
scripts/build-images.sh --rebuild tyger-gateway
scripts/render-units.sh tyger-gateway && systemctl --user daemon-reload && systemctl --user start tyger-gateway
containers/tyger-gateway/scripts/dev-check.sh
```

Start order (the reconnect-storm rule, `PLAN-V03-step2.md` §3): **tyger healthy → gateway healthy →
plexpipe → then link maxaudiod up.** Never the reverse.

## Gate 1 evidence — 2026-11-14, 13:48–13:55 GMT (all on the real chain)

Run by the owner (recorded harness) and by the agent (unrecorded turns), on branch
`v03/tyger-gateway`, image `localhost/tyger-gateway:latest`, tyger-v1 on the 5090.

| # | check (PLAN-V03-step2.md §2) | result |
|---|---|---|
| 1 | exactly one `plex streaming` line; `plex_up:true`, up/down bytes rising | **1** line; `server_up_frames` rising (16732 → 26924); `down_bytes` non-zero each session |
| 2 | gateway log: token decision, `ready` with `hop_ms:320`/`sr:16000`, N mic blocks, reply id + samples, `played:` sent | all present: `token: none (TYGER_API_SECRET unset)`, `ready hop_ms=320 sr=16000 mouth=True voice=max`, `mic blocks=250…15500` at 50/s `dropped=0`, `played:1:272640 sent` |
| 3 | `maxaudiod.json` advanced: connected, down frames grew, gated frames grew | `connected:true`, `rx_frames` 0→150, `gated_frames` 0→444+, `speaking_frames` 0→89, keyed off `last_stat` (the stale `plex_up`/`bridge_up` fields were ignored) |
| 4 | tyger's own log shows the session | `conversation start`, `endpoint by=head turn_s=19.52 segments=1`, `response_onset 310 ms`, `turn_done barged=False … echo -96.3 dB` |
| 5 | MAX Out/Mic recording contains speech whose transcript matches the gateway's reply | `turn-20261114T135033.wav`: speech 18.25–24.77 s = 6.52 s of a 7.20 s reply, seven consecutive seconds of steady RMS; whisper transcription matches the reply text verbatim |
| 6 | `plex streaming` count unchanged over a 60 s idle window | unchanged |

Exact three-way delivery check on one turn (counters, not impressions): the gateway put
**288 000 samples (12.00 s)** on the wire in 150 frames; maxaudiod wrote **282 240 samples (11.76 s)**
to MAX Mic — the 0.24 s difference is exactly 3 header/empty frames. Everything else arrives.

## Open finding: the MAX Mic pair wobbles audio (not V03)

Measured 2026-11-14 13:36 with **no gateway, no tyger and no plexpipe in the picture**: a pure 440 Hz
tone written into MAX Mic with `ffmpeg -f audiotoolbox` and captured back with `ffmpeg -f avfoundation`
comes back with **130 discontinuities spaced ~75 ms**, its energy split across 435–449 Hz instead of one
line (the source tone measures 100 % in-band). The owner's ear on the recorded reply: "lots of breaking
and cracks". The same capture also runs ~11 % short (a 10 s tone spans 8.82 s; a 45 s capture writes a
39.8 s file), which is why a complete reply reads as 91 % in a recording.

This is a MAX Mic / MaxHole property, so personaplex would hit it identically. It is not a V03
deliverable; it is a ticket against the device pair, and Gate 2 (a real Meet) is what says whether a
meeting app hears it.

## How to reproduce

```
# on the ai box
systemctl --user is-active tyger-gateway plexpipe
curl -sS http://127.0.0.1:8994/health
containers/tyger-gateway/scripts/dev-check.sh
podman logs -t systemd-tyger-gateway | grep -E 'ready|endpoint|played:|turn_done|downlink'
# on the Mac (a shell holding the microphone grant)
mac/maxaudiod/gate1-turn.sh          # one turn, recorded off MAX Mic
mac/maxaudiod/gate1-mic-loopback.sh  # known tone through the device pair, gateway not involved
```

## Acceptance

Gate 1 is the real chain without a human: `afplay` a real WAV into MAX Mic → real `maxaudiod --gate` → real
`plexpipe` → this gateway → real tyger on the 5090 → back to MAX Out, recorded with `ffmpeg`. The six
machine-checkable checks are in `PLAN-V03-step2.md` §2; evidence goes here, with timestamps, when it is run.
Gate 2 is the owner in a real Meet. Merge to mainline only after Gate 2.