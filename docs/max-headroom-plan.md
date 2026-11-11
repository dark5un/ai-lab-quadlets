# Max Headroom real-time avatar plan (option A: KB platform down)

Status: EXECUTED 2026-11-11 (Phases 0-4 complete, Phase 5 in progress; see
"Execution record" at the bottom). Outcome deltas from the plan:
- KB units had NO [Install] drop-ins (Phase 1 step 4 premise wrong): the only
  resurrect path was kb-watcher.timer (nightly Wants= chain) — disabled, not
  just stopped. Dormancy now survives reboot natively.
- polerix/headroom (V-15) went private/deleted same day; MVP face replaced
  with a generated procedural wireframe head (no fan-made model assets —
  also better on the Legal note).
- opus-recorder (fork client's lib) pages poison the image's sphn 0.1.12
  reader STATEFULLY on live WS (offline probes pass). Client uplink replaced
  with WebCodecs AudioEncoder + our own Ogg muxer (sphn-exact geometry:
  1 packet/page, granule in 24k units) + handshake-gated send (the server's
  pre-handshake is_alive() probe swallows inbound frames — headers sent
  before 0x00 are lost). 4th fork defect fixed in ppx-moshi-patched
  (read_pcm None guard).
- Voice brain LIVE: personaplex on the 4070 Ti (9.8 GB), TOR measured 0.12 s
  (bench sample candor_turn_taking/1, gate was <=0.5 s); persona prompt
  conditioning verified ("welcome to a special edition").

Key finding that shapes this plan: the lab ALREADY has three full-duplex voice
services adopted from ~/workspace/research/duplex-bus (personaplex, soulx-duplug,
minicpmo-omni quadlet templates, registered in services.json, dormant), with
model weights pre-seeded on disk. PersonaPlex (Moshi-based, 7B 4-bit, ~8 GB VRAM,
full-duplex with barge-in + persona control) is the recommended voice brain;
no cascade needs to be built. See V-11..V-14 for live state.

## Scope decision (owner, resolved at execution)
- Voice core: personaplex (RECOMMENDED — already validated on this exact card per
  quadlets/personaplex.container.in comment) vs soulx-duplug cascade (if Max's
  actual voice matters more than full-duplex feel) vs minicpmo-omni (10-10.5 GB,
  leaves no room for Audio2Face).
- Face tier: MVP = client-side audio->viseme morphs (0 VRAM, polerix/headroom
  pattern); Full = NVIDIA Audio2Face-3D v2.3 as new quadlet (~0.6-1 GB VRAM,
  ARKit blendshapes streamed over WS). Recommendation: MVP first, A2F as phase 3.
- Pipelines: pause kb-papers AND night-kitchen while KB is down (night-kitchen's
  persona-mirror step would fail builds against a down RAGFlow/LightRAG).

## Phase 0 — baseline (read-only, safety net)
1. `tailscale serve status`, `ss -ltn`, `podman ps --format ...`, `podman stats
   --no-stream`, `nvidia-smi --query-compute-apps=pid,gpu_uuid,used_memory`,
   `podman volume ls` — save all to scratch as before-snapshot.
2. Confirm NO running Concourse build for kb-papers/night-kitchen
   (`fly builds`, or ATC REST) before stopping their backends — never kill
   mid-ingest.
3. `git status` in this repo: clean.

## Phase 1 — KB teardown (stop + dorm, fully reversible)
1. Pause pipelines: fly pause-pipeline (8.3 verb: pause-pipeline/unpause-pipeline;
   -p kb-papers -p night-kitchen; wrap in timeout).
2. `systemctl --user stop --now kb-watcher.timer kb-watcher.service` (live state
   2026-11-11: timer active+enabled — V-13).
3. Stop KB services via stack CLI (`ai-lab stop <name>`, dry-run first):
   ragflow, lightrag, kb-analysis (if running), ragflow-nats,
   ragflow-elasticsearch, ragflow-minio, ragflow-mysql, ragflow-kvrocks,
   kb-postgres, then llama-cpp-4070ti.
4. Dormancy (survives daemon-reload/reboot): remove the [Install] drop-ins —
   `podman quadlet rm <name>` for each (podman >= 6.1 owns bookkeeping); verify
   per skill rule: nothing under
   /run/user/$UID/systemd/generator/default.target.wants/ for these units AND
   `systemctl --user is-active` inactive. NOTE: registry boot=false for all grp=kb
   (V-9) — but they were live, so drop-ins exist; remove them or a future
   daemon-reload/re-login resurrects the stack.
5. HARD RULES: touch NO credentials/config files (owner lesson 2026-11-11).
   NO `podman volume rm`, NO `podman system prune --volumes`. Volumes
   (kb-*-data x8, V-14) persist untouched. Model GGUFs under
   ~/.local/share/llama.cpp/cards/4070ti stay on disk.
6. Verify freed: nvidia-smi -> 4070 Ti back to ~all free; ~13.5 GB RSS returned;
   pipeline group (forge/s3/concourse*) still Up; strata-5090-1m UNTOUCHED
   (it lives on the 5090; personaplex's quadlet Conflicts= list includes
   llama-cpp-4070ti — the arbiter must never be asked to move strata here).

## Phase 2 — voice core on the freed 4070 Ti
1. REBUILD missing images — localhost/* tags are NOT prune-protected and grep of
   `podman images` 2026-11-11 shows they are GONE (V-11) while weights remain
   (V-12). Rebuild from duplex-bus sources:
   `podman build -t localhost/personaplex-quant:latest
   ~/workspace/research/duplex-bus/src/cookertron-ppx` (template comment records
   3 fork defects already fixed in that Dockerfile; confirm against
   research/duplex-bus/reviews/personaplex-quant-path.md before building).
2. `ai-lab start personaplex` -> plain WS 127.0.0.1:8998 (V-9), model volumes
   already wired in the quadlet (personaplex-4bit + moshiko-bf16).
3. Prove duplex with the existing harness: duplex-bus bench assets
   (~/workspace/research/duplex-bus/benchdata, MEASUREMENTS.json).
   Gate: responsive full-duplex round trip; Moshi-class expected <= ~500 ms.
4. Persona: Max Headroom system/roleplay instruction (stutters, insults, 80s
   TV-host register). PersonaPlex persona conditioning is model-native.

## Phase 3 — face
Tier MVP (no GPU): browser-side Web Audio analysis (FFT/level -> 5-8 mouth
morphs), polerix/headroom pattern (V-15: existing Max Headroom three.js project
with 8 phoneme shapes + real-time audio-reactive animation; clone to
~/workspace/github.com/polerix/headroom; fan-made Max model = personal use only,
see Legal).
Tier Full (new service, follow references/new-service-checklist.md):
max-face quadlet on 4070 Ti: NVIDIA Audio2Face-3D SDK v2.3 regression model
(MIT, TensorRT, ~0.6 GB VRAM, documented 453 FPS on a 4090 — V-16) fed the TTS
audio stream, outputs ARKit blendshape weights per frame over WS on ai.network.
Prereq to resolve at execution: CUDA >=12.8 <13.0 + TensorRT >=10.13 <11 inside
the image (V-17, from the SDK README) — base image nvidia/cuda:12.x-runtime +
TRT; Ada (sm_89) support is not in question. Registry slot: next free host_port
from the precedence rule (registry host_port + all PublishPort + live ss -ltn),
gpu=4070ti, tier=opt-in, boot=false, policy-test allowlist + services.json +
render-units + docs/port-plan row.
VRAM budget: personaplex ~8 + A2F ~1 + CUDA contexts ~0.6 = ~9.6 / 12.3 GB -> fits.

## Phase 4 — client app + doors
1. Static app (three.js or Rive-WASM renderer + Max model + WS client) placed in
   the dufs tree (dufs live, host 3112, boot=true — V-9) OR a dedicated
   directory under its volume; app fetches model assets from same origin.
2. Secure-context requirement: browser getUserMedia needs https (not localhost
   when remote) -> add per-service tailscale serve listeners on NEW ports
   (`tailscale serve --bg --https=<free> http://127.0.0.1:<port>`, check
   `serve status` first; never re-route :443 root) for (a) the app/static port
   and (b) the personaplex 8998 WS (serve proxies WebSocket upgrades; verify
   live before committing to it — execution-time fact-check).
3. Client connects: wss://door -> PersonaPlex duplex audio both directions;
   local or streamed blendshapes drive the head. Zero heavy compute in browser.

## Phase 5 — acceptance
- Voice-to-face latency measured (duplex harness timestamps), target <= 500 ms.
- Scripted round-trip: fixture audio in -> reply audio out + viseme/blendshape
  frames observed; transcript sane + persona stutters present.
- Headless-Chromium CDP screenshot diff to prove the avatar animates (fake
  media device flags) + one real-browser mic session by owner.
- Rollback drill (same day as any completion): `ai-lab start` the KB units,
  re-add [Install] drop-ins (podman quadlet install), kb-watcher timer on,
  unpause pipelines, verify RAGFlow health via kb-bot API key from
  config/kb-watcher/service.env (NO credential writes), one kb-papers build
  green against the accumulated doc-inbox backlog.

## Risks / notes
- KB offline: svc:notebook/RAGFlow/LightRAG doors dark; papers backlog queues
  in Garage doc-inbox (ingest resumes on unpause — no loss).
- Localhost images pruned once already; add a protection note to the new-service
  checklist flow or rebuild after every `podman system prune`.
- PersonaPlex's voice is the model's own (male, expressive) — not Matt Frewer.
  Owner's call: acceptable persona-wise, or swap to cascade + Max voice via
  Piper/pocket-tts + client DSP chain (pitch +220 cents, distortion, delay —
  max_clawdroom pattern).
- Legal: Max Headroom is a live trademark (All3Media; US reg 2429052 renewed —
  V-18). Personal/home-lab use fine; no commercial publishing, no public repo
  with the character model (public-repo-hygiene applies).
- Do NOT let anything touch strata: it stays on the 5090 through all of this
  (its units are not in any Conflicts chain we start; gpu-arbiter rule 1 applies
  only to starts targeting the 5090).

## Verification appendix (every claim -> probe, all live 2026-11-11)
- V-1  5090 32607 MiB / 4070 Ti 12282 MiB, driver 615.78.08 —
  `nvidia-smi --query-gpu=name,memory.total,driver_version`.
- V-2  strata = 31,510 MiB on the 5090; llama-server = 9,082 MiB on the
  4070 Ti — `nvidia-smi --query-compute-apps=pid,gpu_uuid,used_memory`
  (UUIDs intentionally not transcribed here; live lookup via
  `nvidia-smi --query-gpu=name,uuid`).
- V-3  llama-server cmd: gemma-4-12b-it-qat-q4_0, ctx 262144, mmproj, loopback
  39685 — `tr '\0' ' ' < /proc/287826/cmdline`.
- V-4  RAM: 117/125 GB used, swap 15/15 — `free -g`.
- V-5  Per-container RSS: strata 104.4 GB, llama-cpp-4070ti 9.202 GB,
  ragflow-elasticsearch 2.058, ragflow 1.74, minio 220.6 MB, mysql 107 MB,
  lightrag 157 MB, kvrocks 34.3 MB, kb-postgres 33.5 MB, embeddings 91 MB —
  `podman stats --no-stream`.
- V-6  4070 Ti free with llama down: 12,282 - ~190 (contexts) ≈ 12.1 GB —
  arithmetic on V-1/V-2.
- V-7  Whisper throughput: faster-large-v3-turbo fp16 13-min audio in 19.2 s,
  int8 1545 MB — faster-whisper GitHub discussion #1030 benchmark table.
- V-8  Voice-agent latency anatomy: VAD 200 + STT 120 + LLM TTFT 180 + TTS
  110 ≈ 610 ms; Pipecat/Modal target ~1 s — smrussel.dev pipecat post +
  modal.com low-latency-voice-bot blog.
- V-9  grp=kb membership (ragflow, ragflow-elasticsearch, ragflow-mysql,
  ragflow-minio, ragflow-kvrocks, ragflow-nats, kb-postgres, lightrag,
  kb-watcher, kb-analysis; all boot=false) + soulx-duplug 8000 / personaplex
  8998 / minicpmo-omni 9060 on gpu=4070ti (opt-in, boot=false) + dufs 3112
  boot=true — services.json parsed live.
- V-10 GPU arbiter rules (strata owns card; non-strata share; exclusive set) —
  docs/gpu-assignment.md + scripts/gpu-arbiter.py in repo.
- V-11 NO localhost/personaplex-quant, soulx-duplug, minicpmo-omni-runtime
  images present — `podman images | grep -E 'personaplex|soulx|minicpmo'`
  (empty). Weights exist though.
- V-12 personaplex-4bit 6.6 GB + moshiko-bf16 15 GB + soulx-duplug +
  minicpmo-4_5-gguf dirs present — `du -sh` / `ls` under
  ~/.local/share/ai-lab/models.
- V-13 kb-watcher.timer active+enabled — `systemctl --user is-active/-enabled`.
- V-14 named volumes kb-{nats,es,minio,kvrocks,mysql}-data, kb-ragflow-logs,
  kb-lightrag-{pg-}data — `podman volume ls` (preserve on stop).
- V-15 polerix/headroom: three.js Max Headroom, 8 phoneme shapes, Web Audio
  real-time lipsync, OBJ/MTL — repo README (web search 2026-11-11).
- V-16 Audio2Face-3D: MIT SDK + open weights (v2.3 regression ~0.6 GB TRT for
  8 tracks; 453 FPS v2.3-Claire TensorRT on 4090; streaming; ARKit blendshapes;
  C++ SDK real-time) — github.com/NVIDIA/Audio2Face-3D-SDK README +
  arxiv.org/html/2508.16401 (tables 1 + memory section).
- V-17 SDK prereqs CUDA >=12.8 <13.0, TensorRT >=10.13 <11, Linux — same README.
- V-18 Max Headroom rights: All3Media (Wikipedia, Nov 2007 note); US reg
  2429052 "REGISTERED AND RENEWED", serial 75375195 — USPTO TTABVUE 91178318.
- V-19 Piper RTF: 5950X ONNX medium 0.030 / first-audio 180 ms (short);
  pocket-tts first audio 71 ms — rhasspy/piper issue #33 benchmark +
  HF blog VoxRT small-CPU-TTS comparison.
- V-20 PersonaPlex 7B 4-bit ~8 GB VRAM on 4070 Ti; cookertron fork +
  pre-quantized model_bnb_4bit.pt; minicpmo-omni duplex sanity PASS on this
  card (~43 ms/chunk 2026-10-12) — quadlet template comments +
  research/duplex-bus (host tree).

## Execution record (2026-11-11)
- Phase 0: snapshots -> scratch; no in-flight kb builds (ATC REST); git clean.
- Phase 1: pipelines paused via ATC REST; kb-watcher.timer DISABLED (plan's
  [Install]-drop-in premise was wrong: KB units never had autostart; the
  timer's nightly Wants= chain was the only resurrect path); 9 units stopped.
  Verified: 4070 Ti 1 MiB/12282 used, ~14 GB RSS returned, all 8 kb-* volumes
  intact, zero credential-touch, pipeline group + strata unaffected, nothing
  KB-related under generator/default.target.wants.
- Phase 2: personaplex-quant image rebuilt (fork Dockerfile matches the 3
  documented defect fixes); render-units + policy tests green; server LIVE on
  127.0.0.1:8998, 9.8 GB VRAM. Bench: fdb round trip + transcribe on real
  audio (candor_turn_taking/1): TOR ~0.12 s <= 500 ms gate. Max persona
  conditioning verified. (4070 Ti float32 wavs need s16 conversion first.)
- Phase 3 MVP: apps/max-headroom (Vite + three.js). Procedural wireframe head
  (polerix/headroom went private the same day; generated head also avoids
  fan-made model assets). 8 viseme morph targets computed from geometry
  params (open/purse/widen/protrude); FFT+ZCR band classifier (face.js);
  CRT shell (scanlines, shades toggle 's'). Tier Full (Audio2Face-3D) NOT
  built — deferred (fits: 12.3 - 9.8 = 2.5 GB > ~1.6 needed).
- Phase 4: client = src/plex-client.js (WebCodecs AudioEncoder uplink via
  src/ogg-muxer.js, Ogg-demux + AudioDecoder downlink, handshake-gated).
  Door: `tailscale serve --bg --https=8456 -> 127.0.0.1:8998`; WS-through-
  serve VERIFIED live (browser e2e over wss). App served by dufs at the
  existing :443 root door under /workspace/.../apps/max-headroom/dist/
  (401 = auth gate; no new static door needed). Persona + door editable in
  UI; defaults in URL params.
- Phase 5 browser acceptance (`python test_app_e2e.py`, Playwright Chromium,
  file-backed fake mic): GATE 1 LIVE; GATE 2 downlink bytes; GATE 3 viseme
  influences [1.00,...]; GATE 4 screenshot pair differs (animating);
  upPages=312 downBytes=13k + streamed 0x02 captions. PASS direct-loopback
  AND through the wss :8456 door. Zero console fatals.
- Rollback drill (KB -> sleep -> up): ragflow /v1/system/health 200 (route
  differs from plan's guess), kb-bot PAT lists 5 datasets (code 0), lightrag
  /health 200, kb-papers unpause + triggered fetch-papers build #14383 ->
  green (auto-spawned kb-ingest-papers #14395 draining the paused-week
  doc-inbox backlog; dataset counts observed rising live). llama-cpp-4070ti
  NOT restarted during the drill (personaplex holds the card; Conflicts=
  makes them mutually exclusive by design).
- Pending owner items: one real-browser mic session by owner; end-state call
  (KB back to sleep after backlog drains, or leave up — avatar unaffected
  either way as long as llama-cpp-4070ti stays off the 4070 Ti).
