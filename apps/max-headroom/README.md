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

Protocol notes (all live-verified 2026-11-11, see also duplex-bus STATUS.md):
- Frames: 1-byte kind + payload. 0x00 handshake, 0x01 Ogg-Opus bytes both
  directions (server fragments pages arbitrarily), 0x02 utf8 text stream.
- Uplink MUST be sphn-exact Ogg geometry (one packet per page, granulepos in
  24k units) — src/ogg-muxer.js; and pages must wait for the 0x00 handshake
  (the server's pre-handshake is_alive() probe swallows inbound frames).
- Audio is 24 kHz mono throughout.

LEGAL: Max Headroom is a live trademark (All3Media). Personal/home-lab use
only; no commercial publishing, no distribution of character-model assets.
