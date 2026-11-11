# Max Headroom v2 — real face + joins calls plan

Status: PLAN (not executed). Owner decisions 2026-11-11: (1) current graphics
are awful — redesign with GPU blendshape animation, (2) the avatar must be able
to JOIN calls (Google Meet) with its face as the camera and its voice streamed
as the mic, both directions, full-duplex.

Baseline state (verified 2026-11-11): personaplex live on 4070 Ti (9.8 GB,
loopback :8998), wss door :8456, app under dufs :443 root
(/workspace/github.com/dark5un/ai-lab-quadlets/apps/max-headroom/dist/),
acceptance gates green (v1 record in max-headroom-plan.md). KB stack masked+asleep.

## What v1 gets wrong visually (from live screenshot review)
- Head is a stretched UV-sphere blob: zero facial topology, features are flat
  2D decals (visor bar, eye half-discs) that ignore curvature.
- Viseme morphs run but are INVISIBLE from outside (mouth not readable) — the
  8-parameter morph-over-egg approach is fundamentally limited.
- Flat unlit surface + single hot facet + stray magenta blob; wireframe does
  all the form-reading. CRT scanline filter smears the HUD text.
- HUD: raw ws:// URL exposed, OFF AIR red square off-palette, persona text
  truncated, "streaming / ow" glitch text. No "is he speaking?" state.

## Architecture (target)
```
personaplex (24k audio)                browser client          max-call bot (Meet)
   |  downlink PCM                       | getUserMedia? NO       | aiortc tracks
   v                                     v                        v
max-bridge (python WS hub)  <---- taps downlink (bot: direct; browser: posts it back)
   |  feed 16k/24k audio to
   v
max-face (A2F-3D local inference, GPU 4070 Ti)  -> 51 ARKit blendshapes + emotion, 30fps
   |  fan out (timecoded frames)
   +----------------------------------------------+
   v                                              v
three.js renderer facecap.glb (MIT, 52 ARKit   headless Chromium "studio" tab
morph targets) + procedural head/eye motion     CDP screencast 30fps -> VP8 track
+ CRT screen-face styling + redesigned HUD      + downlink PCM -> Opus mic track
                                                + Meet far-end audio -> plex uplink
```

## Phase 0 — probes + baseline (read-only)
1. VRAM fit gate (HARD): current free on 4070 Ti = 12282-9835 ~2.4 GB.
   Probe max-face options' actual VRAM: A2F-3D NIM (nvcr.io digital-human NIM —
   check model size + min VRAM in NVIDIA docs) vs standalone SDK v2.3 regression
   (~0.6-1 GB, TensorRT, CUDA>=12.8 <13.0 + TRT>=10.13 <11 per V-17 v1 plan).
   If NIM cannot fit next to personaplex -> use the SDK path. Record which.
2. facecap.glb availability + morph-name audit: three.js repo examples/models/
   gltf/facecap.glb (MIT, ~332KB); enumerate morphTargetNames in three, map to
   the 51 A2F ARKit names (expect _L/_R naming drift — build the mapping table
   from the actual mesh, not from blogs).
3. plex audio taps: confirm bot path can pull clean PCM downlink from plex WS
   (already proven: v1 e2e) and feed plex uplink without the browser.
4. Baseline snapshots (net/gpu/units) -> scratch/max-headroom-v2/.
5. `git status` clean.

## Phase 1 — max-face service (new quadlet, follow references/new-service-checklist.md)
- grp=avatar, gpu=4070ti, tier=opt-in, boot=false; next free host_port per
  registry precedence rule; services.json + policy-test allowlist + port-plan row.
- Image decision from P0.1. Container serves gRPC (A2F-3D bidirectional
  ProcessAudioStream) on ai.network only. Model weights cached in a named volume
  (no home-dir state; never `podman system prune --volumes`).
- max-bridge: python service (same quadlet unit or sidecar) — single owner of
  the plex<->face<->clients fan-out WS at 127.0.0.1 (door via tailscale if the
  browser needs it; reuse :443 app door for the client WS).
  Protocol v1 (already client-side): 8 visemes -> v2: {t, bs[51] in ARKit order,
  emotion}; handshake carries shape names.
- Gate: fixture wav in -> CSV/WS blendshape stream out; JawOpen/Mouth* visibly
  modulated; 30fps cadence; latency bridge->client <= 150 ms on tailnet probe.

## Phase 2 — renderer redesign (apps/max-headroom v2)
- Replace blob: load facecap.glb (vendored into repo assets with LICENSE note),
  drive 51 morphs from bridge stream; keep wireframe+CRT as *shader* on top of a
  real face (mannequin/chrome material, fresnel rim, phosphor green-cyan
  palette only — kill stray magenta/red).
- Own what A2F doesn't do: procedural head pose (Max's 2-3deg micro-jitter,
  turn-to-speaker feel), eye gaze + blinks (EyeBlink from A2F, gaze procedural).
- HUD redesign: ON AIR/OFF AIR as a proper broadcast state light, mic level
  meter + "LISTENING/THINKING/SPEAKING" state, captions bar at bottom, gear
  panel for door/persona (defaults hidden), no raw URLs, no truncated text,
  scanline shader applied to the 3D viewport only, not DOM text.
- Design pass: use popular-web-designs / claude-design craft standards; before/
  after screenshot pairs reviewed with owner taste (owner called v1 "awful").
- Gate: v1 e2e still passes end-to-end through the bridge (visemes from A2F),
  screenshot pair diff animating, mouth visibly open on "ah" fixture.

## Phase 3 — max-call: avatar joins Google Meet (kernel-free)
- New service dir apps/max-call (python, uv-managed venv, aiortc + websockets
  + sounddevice-free: PCM handled in-process; CDP via playwright chromium):
  1) Playwright headless chromium opens the Meet guest link, clicks "join now"
     with fake-UI flags, extracts signaling via the meetbot pattern (CDP DOM
     read of the WebRTC offer path) OR runs entirely as participant via the
     room's chat/WebSocket signaling it exposes — P0 spike decides (throwaway
     spike first: can we complete one handshake from THIS host at all?).
  2) Media: aiortc RTCPeerConnection — VideoStreamTrack from CDP screencast of
     the studio tab (face rendered by our own app page, no mic, subscribed to
     bridge), AudioStreamTrack from plex downlink (24k->48k resample).
  3) Ear: Meet far-end audio (aiortc recv track, Opus->PCM 48k) -> resample
     24k mono -> plex uplink (same framing the v1 client uses: WebCodecs not
     needed python-side; use ogg/sphn path proven by duplex-bus harnesses).
  4) Controls: OFF AIR = stop sending tracks (keep connection); auto-leave
     when alone in call; single-instance lock.
- SPIKE RULE: if Meet refuses non-browser participants or breaks handshake,
  fall back in order: Jitsi quadlet (same code, clean signaling) -> browser
  room PoC. Owner chose Meet; the plan keeps the fallback honest.
- Gate: Panos joins from phone on tailnet, talks to Max end-to-end; measured
  round-trip latency <= ~1.2 s (duplex 0.12 s + call codec budget); face
  animates in the far-end tile.

## Phase 4 — wiring + acceptance + record
- tailscale doors as needed (bridge WS may reuse existing 8456-family pattern
  on a NEW port; check `tailscale serve status` first, never re-route :443).
- READMEs + port-plan + services.json rows; execution record appended here;
  commit; screenshot pair + call-recording evidence saved to scratch.
- Rollback drill: avatar back to v1-browser-only mode (bridge optional, client
  falls back to local 8-viseme classifier — keep v1 path alive behind a flag).

## Risks / notes
- Google fragility/ToS: personal home-lab use; bot joins as guest via
  owner-created link; no account creds stored anywhere (vault rule).
- VRAM tight: P0.1 decides NIM vs SDK; personaplex is the anchor (do not
  disturb — user is live on it); llama-cpp-4070ti stays masked/off while
  avatar mode is on (Conflicts= already encodes this).
- CPU: VP8 encode (libvpx in aiortc) ~1-2 cores for 720p30 — fine (24t);
  target 480p640 first.
- facecap.glb morph naming/mapping is the one place blogs disagree — build the
  table from the loaded mesh programmatically (P0.2).
- Legal unchanged: no fan-made Max model assets; A2F NIM/SDK weights under
  NVIDIA models license — personal use fine, keep out of any public repo.

## Verification appendix (to be filled live at execution; source-verified now)
- V-1  A2F-3D NIM v1.3: gRPC ProcessAudioStream bidirectional, 51 ARKit
  blendshapes + emotion, 30 inferences/sec of audio, eye-look/head/tongue
  always 0 — docs.nvidia.com/ace/audio2face-3d-microservice/1.3 (sample-app +
  a2f-rpc + audio2face-ms pages, fetched 2026-11-11).
- V-2  facecap.glb: MIT, three.js examples, 52 ARKit-compatible morph targets,
  ~332KB/~27K verts — found via Demerzel project design doc (github
  GuitarAlchemist/Demerzel) — MUST re-verify morph names from the actual file.
- V-3  aiortc: binary wheels on PyPI (Linux x64), VP8/H264 + Opus, Chrome-
  interop-tested — aiortc README. Newer MarshalX/python-webrtc (pip wrtc,
  libwebrtc M152) is a candidate upgrade if VP8 quality/interop hurts.
- V-4  Meet bot prior art: guest-join via browser automation + aiortc media
  handoff (adriancast/Google-Meet-ai-bot "meetbot" pattern; nandannsr/Gmeet-bot
  records-only variant) — brittle by nature; spike gates it (Phase 3 SPIKE RULE).
- V-5  No kernel camera/audio on this box: v4l2loopback absent, no
  /dev/video*, no pipewire/pulse in user session — probed 2026-11-11.
- V-6  4070 Ti headroom now ~2.4 GB — nvidia-smi probe 2026-11-11.

## Execution record

### Phase 0 (2026-11-11, this session)
- Baseline snapshot -> scratch/max-headroom-v2/before-snapshot.txt (GPU: 4070 Ti
  2.4 GB free beside personaplex; ports 8998/3112 live; KB stays masked).
- P0.1 VRAM engine decision: NIM 1.3.16 + OWN single-stream/batch-1 TRT
  generation -> NVIDIA-measured ~0.9 GB (edge-deployment note in docs); stock
  defaults (10 streams, batch<=128) would use 9-15 GB and are NOT used.
  SDK (C++, MIT) rejected: library-only, needs a service wrapper + CUDA/TRT
  build -> more work. gRPC endpoint verified from docs: bidirectional
  :52000 (deployment_config endpoints.bidirectional.server.url).
- P0.2 facecap.glb audited from the actual file: mesh 2 carries 52 morph
  targets, ARKit-style names (browInnerUp, jawOpen, mouthSmile_L ...); file
  uses EXT_meshopt_compression (fallback) -> MeshoptDecoder needed; MIT.
- Client-wheel truth: the PyPI nvidia-audio2face-3d wheel speaks a DIFFERENT
  dialect (AudioWithEmotionStream/blend_shape_animation) than what the NIM
  serves (controller.v1 AudioStream / SkelAnimation.blend_shape_weights) AND
  pins protobuf==4.24.1 transitively. Use the samples' nvidia_ace-1.2.0 wheel
  (--no-deps) + grpcio 1.76 + protobuf 7.36.2.
- BLOCKER-DISCOVERED+FIXED during integration (fact #78): accessing an
  INACTIVE oneof member on upb messages inside a streaming servicer silently
  terminates the request iterator after the first message (reproduced across
  grpcio 1.67/1.76, protobuf 4.24/7.36; both aio and sync). Fix: WhichOneof-
  first dispatch everywhere. Without the probe-first investigation this would
  have looked like "NIM is broken" at deploy time.

### Phase 1 (2026-11-11)
- containers/max-bridge (python 3.12-slim; sync grpc clip loop in a thread,
  websockets fan-out hub; protocol {t, bs{51 ARKit names}} @30Hz on :8990
  /feed /shapes; 240 s clip rotation + silence keepalive per NIM low-fps rule).
- Integration-tested against a same-protos FAKE NIM (mirrors documented
  server): drive_test PASS -> hello names + 60 frames + ramp; then the actual
  IMAGE re-tested containerized: LOOP OK. Production quadlet max-bridge live
  on 127.0.0.1:8990 (active, WS connect verified).
- quadlets/max-face.container.in + config/max-face/* (run.sh two-phase
  generate->serve per NVIDIA quick-start; advanced/deployment configs patched
  to stream_number:1 shapes:1; james stylization vendored). NGC_API_KEY =
  owner input required -> max-face NOT started yet; everything else ready.
- Registry: services.json rows (group=avatar), build-images.sh avatar case,
  install.sh UNITS, port-plan rows. render-units + test-quadlet-policy PASS.

### Phase 2 (2026-11-11) — renderer v2 (subagent-built, parent-verified)
- apps/max-headroom v2: vendored facecap.glb (MIT, byte-checked) + LICENSE note
  + KTX2/Basis transcoders; src/face2.js (chrome-mannequin MeshPhysicalMaterial,
  fresnel rim, dark inner shell, catchlights, neck+collar pedestal, procedural
  jitter/turns/saccades, CRT post inside canvas only); src/feed2.js
  (synthetic|bridge|file feeds, staleness watchdog); src/morph-map.js GENERATED
  52/52 ARKit<->facecap pairs (tools/gen-morph-map.mjs reads gltf extras).
- HUD v2: ON AIR pill, STANDBY/LISTENING/THINKING/SPEAKING, telemetry
  (fps/bs/s-out/mic), caption bar (0x02 stream), CFG gear hides door/persona,
  no raw URLs, cyan-only + amber warning (red/magenta dead).
- v1 kept intact: ?v2=1 toggle (bootstrap.js), v1 e2e re-run PASS by parent.
- FULL-CHAIN INTEGRATION PROOF (parent): real 28.8 s speech PCM -> production
  max-bridge quadlet (:8990) -> proto-faithful fake NIM container (ai.network
  alias systemd-max-face) -> v2 app headless feed=bridge: inFrames 50,
  JawOpen ramp 0.26, screenshot shot-v2-chain.png. CHAIN OK.
  (bridge patch: root path '/' also accepted as /shapes consumer.)
- Vision review score: v1 ~2-3/10 -> v2 7/10 (real facial geometry, visible
  open mouth, clean HUD). Known polish backlog: eye iris detail, one-side
  shadow crush, floating bust, dev 'v1' link label.

### Phase 3 spike (2026-11-11, subagent) — apps/max-call scaffold
- aiortc 1.16 + Playwright chromium validated BOTH ways: aiortc<->aiortc
  loopback (29.9 fps VP8 + 49.5 fps Opus) AND headless-Chromium<->aiortc
  interop (browser decoded 148 synthetic VP8 frames ~240 kbit/s). No
  /dev/video needed.
- Meet reality check (live probe from this host): alkaline.google.com is
  NXDOMAIN (legacy bot-token gateway dead); meet.google.com/o/webrtc-inbound-
  call live but auth-gated. => join path = Playwright guest-join + CDP
  signaling interception (observer ran against live Meet UI, screenshots).
  UNVERIFIED until an owner-created meeting link: guest admission flow,
  live token extraction, media servers handshake. join.py --url --hold 60
  is wired to close exactly that.
- Hygiene: tailnet ICE IP redacted from artifacts (validation_results.json).
