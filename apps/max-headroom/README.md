# max-headroom — full-duplex avatar client

Browser app for the lab's PersonaPlex voice core (see
`docs/max-headroom-plan.md` for the stack). Zero heavy compute client-side:
WebCodecs Opus <-> Ogg over WebSocket to PersonaPlex; a procedural three.js
wireframe head animates 8 viseme morphs from FFT analysis of the played
back audio.

Use (tailnet, from any device on `ai`'s tailnet):
  https://ai.<tailnet>.ts.net:443 -> dufs login ->
  /workspace/github.com/dark5un/ai-lab-quadlets/apps/max-headroom/dist/index.html
The app dials `wss://<host>:8456` (tailscale serve door -> personaplex 8998)
by default; door/persona are editable in the control bar. GO LIVE arms the mic.

Dev: `npm install && npm run dev` (loopback: point door at ws://127.0.0.1:8998;
http://127.0.0.1 is a secure context so the mic works).
Acceptance: `~/workspace/research/duplex-bus/.venv/bin/python test_app_e2e.py`
(headless Chromium gates: LIVE, downlink, visemes, screenshot diff).

## v2 renderer (facecap) — `?v2=1`

The redesign loads the MIT-licensed **facecap.glb** scan (52 ARKit morph
targets; vendored in `assets/` with license note) and renders it as a stylized
glossy chrome mannequin in a cyan-phosphor CRT look (fresnel rim + scanline /
barrel / vignette post **inside the WebGL canvas only**, never over DOM text).
New HUD: ON AIR pill, LISTENING/THINKING/SPEAKING state, bottom caption bar
(the 0x02 stream), CFG settings gear (door/persona/feed hidden by default).
The wireframe head (v1) still works at `/` without `?v2=1`, and v1 files are
untouched; `src/plex-client.js` + `src/ogg-muxer.js` are reused as-is.

Blendshape feeds (`?feed=...`, ARKit names -> facecap morph names via the
generated `src/morph-map.js`, 52 verified pairs — regenerate with
`node tools/gen-morph-map.mjs`):

- `feed=synthetic` (default): local mic-level + spectral analysis -> ARKit
  frames. Works with no backend at all.
- `feed=bridge`: live WS at `?door=` (default `ws://127.0.0.1:8990`) speaking
  JSON `{t: unix_seconds, bs: {ARKitName: 0..1}}` @30Hz — the A2F contract.
  Fake it with `python tools/fake-bridge.py` (streams the CSV fixture).
- `feed=file`: replays `tests/fixtures/bs-frames.csv` (served at
  `/fixture/bs-frames.csv` by vite in dev and preview). Regenerate with
  `node tools/gen-fixture.mjs`.

Audio door (PersonaPlex) is `?plex=` (default loopback `ws://127.0.0.1:8998`
or the tailscale wss on non-loopback hosts); GO LIVE arms the mic exactly like
v1. Extra params/controls: wireframe overlay = CFG checkbox; `?teeth`
re-enables the (hidden-by-default) teeth mesh.

Acceptance: `~/workspace/research/duplex-bus/.venv/bin/python test_app_v2.py`
— gates synthetic/bridge/file morph engagement, the live ON AIR pill +
LISTENING/SPEAKING state + caption stream, and writes comparison screenshots.
View it locally: `npm run build && npm run preview` then open
`http://127.0.0.1:4173/?v2=1` (or `npm run dev`).

Protocol notes (all live-verified 2026-11-11, see also duplex-bus STATUS.md):
- Frames: 1-byte kind + payload. 0x00 handshake, 0x01 Ogg-Opus bytes both
  directions (server fragments pages arbitrarily), 0x02 utf8 text stream.
- Uplink MUST be sphn-exact Ogg geometry (one packet per page, granulepos in
  24k units) — src/ogg-muxer.js; and pages must wait for the 0x00 handshake
  (the server's pre-handshake is_alive() probe swallows inbound frames).
- Audio is 24 kHz mono throughout.

LEGAL: Max Headroom is a live trademark (All3Media). Personal/home-lab use
only; no commercial publishing, no distribution of character-model assets.
