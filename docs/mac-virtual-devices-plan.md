# MaxPresence — custom Mac virtual camera + mic, fed by the ai-lab server

Status: PLAN v2 (investigated 2026-11-12; owner directive: build it ourselves,
task-specific — no OBS/BlackHole as end-user tools; fork only where the OS
forces a driver shape). Mac side is built by Hermes-on-the-Mac from this brief.
Scenario: Panos joins Meet incognito from the stepping-stone Mac like any
human; picks "MAX Camera" + "MAX Mic" devices that this tool produces from
the server stack (personaplex + max-face + max-bridge). Zero browser
automation, zero Google bot-gate fights (fact #79 killed the CDP route to
fallback-only).

STEPPING-STONE MACHINE (owner, 2026-11-12): **code-m2** — a Mac separate
from mini-m4 (mini-m4 stays the rerank/MLX inference node). tailnet
<code-m2-tailnet-ip>, user panos@, currently NO ssh from ai (port 22 refused —
enable Remote Login if the Mac Hermes needs remote help, otherwise work
happens locally on code-m2 where its own Hermes runs). Expect macOS 13+
(M2-era): confirm sw_vers at P-1; per-app output device assignment needs
macOS 14+.

## Verified DIY mechanisms (source-checked 2026-11-12)
- V-1 VIDEO: CoreMediaIO **Camera Extensions** (WWDC22 session 10022, macOS
  12.3+; DAL plugins are dead). Swift: ProviderSource/DeviceSource/
  StreamSource; the extension runs sandboxed in its own daemon; installed
  via SystemExtensions from a host app that MUST live in /Applications;
  user approves once (System Settings -> General -> Login Items &
  Extensions -> Camera Extensions). Visible to every app incl.
  Chrome/Meet/Safari (this is exactly how OBS >=30 does it). External frame
  feed pattern: host app pushes frames to the extension (demo:
  github.com/ldenoue/cameraextension; write path: CVPixelBuffer ->
  CMVideoFormatDescriptionCreateForImageBuffer ->
  CMSampleBufferCreateReadyWithImageBuffer -> stream.send(sbuf,
  hostTimeInNanoseconds:)).
- V-2 AUDIO: CoreAudio **HAL plugin** = user-space .driver bundle in
  /Library/Audio/Plug-Ins/HAL; no kext, no security-policy changes even on
  Apple Silicon (BlackHole README verbatim: "No kernel extensions or
  modifications to system security necessary"); loads with Team=None /
  ad-hoc signing for personal machines; after install: `sudo killall -9
  coreaudiod`. We fork BlackHole (GPLv3 — fork stays PRIVATE) and use its
  documented compile-time constants (kDriver_Name, kPlugIn_BundleID,
  kDevice_Name, kDevice_HasInput/Output, kDevice2_*, kLatency_Frame_Size,
  kSampleRates) to ship ONE driver "MaxHole" exposing exactly:
    "MAX Mic"  — output side: our agent plays Max's voice INTO it;
                 input side: the meeting app selects it as microphone.
    "MAX Out"  — output side: the meeting's speaker goes INTO it (set as
                 Meet/Chrome output device or via Multi-Output Device);
                 input side: our agent records what the meeting said.
- V-3 Devices are pipes, feedback-safe: two separate pipes (Mic vs Out)
  means no self-echo loop; Panos hears the meeting via a Multi-Output
  Device (headphones + MAX Out) or macOS 14+ per-app output assignment.
- V-4 Rates: build MaxHole kSampleRates={48000,24000}; agent resamples
  24k (plex native) <-> 48k (CoreAudio default) — libsamplerate or
  AVAudioConverter on Mac; ffmpeg on server.
- V-5 Transport: tailnet — code-m2 and ai are already peers on the same
  tailnet (both in `tailscale status`). Server exposes plexpipe via
  `tailscale serve --https=84xx` (WSS door pattern already proven live
  with the :8456 plex door).
- V-6 Rendering: P1 server-side (headless chromium screencasts JPEG frames
  down the door — the exact pipeline apps/max-call already proved);
  polish phase Mac-side (extension renders blendshape JSON -> three.js
  facecap morphs; payload = bridge /shapes frames {"t":..,"bs":{52 names}},
  reference renderer apps/max-headroom/src/face2.js).

## Component inventory
SERVER (this repo — I build this, protocol frozen for the Mac brief):
- **plexpipe** service: quadlet (group avatar, boot=false, loopback :8991)
  + tailscale WSS door. One Mac session at a time. Protocol (JSON control
  + binary media, 20 ms frames):
    C->S {"t":"hello","v":1,"caps":["audio","video"]}
    C->S binary tag 'A' = meeting audio s16le 48k mono (MAX Out capture)
    S->C binary tag 'A' = Max's voice s16le 24k mono
    S->C binary tag 'V' = JPEG frame 640x480 (15-30 fps, option (a))
    S->C {"t":"stat",...} heartbeats; S->C {"t":"shapes"} later for option (b)
  Internally: 'A' uplink -> ffmpeg 48k->24k -> personaplex mic uplink
  (framing = apps/max-headroom/src/plex-client.js; the proven python
  mirror = PlexFeed in apps/max-call/src/maxcall/callpage.py); plex reply
  audio -> fan out: (1) downlink 'A' to Mac, (2) max-bridge /feed (lips).
  Bridge /shapes frames -> downlink (option b) or server-render -> 'V'.
MAC (Hermes-on-Mac builds from this brief):
1. **MaxHole** — BlackHole fork, renamed per V-2, two-device build,
   installed via a small pkg/script (post-install: killall coreaudiod).
2. **maxaudiod** — launchd agent (Swift preferred; Python OK for P1):
   CoreAudio InputStream(MAX Out) -> WSS up; WSS down -> OutputStream
   (MAX Mic); resampler; reconnect backoff; os_log.
3. **MaxCamHost.app** — menu-bar app; installs/activates the camera
   extension (SystemExtensions; app in /Applications; entitlement
   com.apple.developer.system-extension.install; app group prefixed by the
   extension's MachServiceName); WSS client for 'V' frames; XPC -> extension.
4. **MaxCamExtension** — Camera Extension target (Xcode template): one
   device "MAX Camera", one stream 640x480@30; receives frames over XPC;
   sends CMSampleBuffers with host-time PTS (V-1 write path). Later:
   receives blendshape JSON and renders locally (option b).

## Phases
- P-1 CODE-M2 ENV (Mac Hermes): sw_vers / chip / brew / Xcode CLT presence;
  tailscale status (must see ai); decide Remote Login on/off for cross-
  debugging; create a private dir for the MaxPresence sources.
- P0 SERVER: implement plexpipe + door + protocol doc; loop-test with a
  python client (no Mac): feed recorded speech -> hear plex reply downlink
  + bridge lip animation. GATE: round-trip audio < 1 s.
- P1 MAC audio: MaxHole + maxaudiod (python prototype ok). Manual test in
  Meet incognito: Panos' browser mic=MAX Mic, speaker=Multi-Output
  (phones+MAX Out); plexpipe uplink = meeting audio; GATE: Max answers the
  meeting out loud into the call.
  STATUS 2026-11-12 (code-m2): MaxHole 0.1.0 installed + ad-hoc loaded by
  coreaudiod; device-loop gate **PASS** (owner-run `maxaudiod.py
  loopback-test`: both pipes self-loop tone-peak=1.00, cross-leak 0.00 —
  per-device ring-buffer fix confirmed). Meet gate pending P0 door URL.
- P2 MAC video: MaxCamHost+MaxCamExtension, JPEG 'V' path. GATE: QuickTime
  shows MAX Camera with Max animating (server-rendered).
- P3 FULL JOIN: incognito Meet with MAX Cam + MAX Mic: 10-minute
  conversation; GATE: speech-to-motion latency <= 450 ms measured, no echo,
  no artifacts.
- P4 POLISH: option (b) local rendering (shapes over WSS -> Metal offscreen
  three.js), launchd orchestration one-click "go live", idle/speaking
  states, maybe VP8 instead of JPEG.

## Pitfalls (paid for already — hand to Mac Hermes verbatim)
- System extension only installs from /Applications — add a ditto build
  post-action (garethpaul.com write-up).
- Extension Info.plist MachServiceName is mandatory; app-group entitlement
  validation requires the provider-id prefix.
- Restart coreaudiod after MaxHole changes; Chrome/Meet enumerate devices
  at launch — fully restart the browser after driver install.
- Meet's noise suppression may gate synthetic voices: turn off voice focus
  / noise cancellation in Meet settings if Max gets squashed.
- ffmpeg cannot OUTPUT to audio devices on macOS (avfoundation is capture-
  only) — hence the sounddevice/AVAudioEngine play path in maxaudiod.
- plex wire format is OGG/opus inside the door protocol; plexpipe converts
  ogg<->PCM SERVER-side so maxaudiod is pure PCM. Keep Mac side dumb.
- Latency budget: plex TOR ~120 ms + tailnet ~5 ms + CoreAudio buffers
  ~30 ms + video pipeline ~50 ms => <=450 ms achievable.
- VRAM settled: personaplex + max-face (~790 MiB) coexist on the 4070 Ti.
- GPLv3 MaxHole fork: private repos only. Never name anything "ryoku".
- **Owner policy (code-m2, 2026-11-12)**: the agent must NOT open CoreAudio
  input/microphone streams — capture-verifying tests are run BY THE OWNER or
  verified via meters while the agent plays output-only. Ask each time.
- **portaudio/AUHAL cannot open separate input and output streams on the
  SAME device** (-10863 "cannot do in current context"); self-loop tests need
  one duplex sd.Stream(device=(in_idx, out_idx)).
- **pkgbuild --root flattens its argument** — with --root <bundle> the
  Contents/ lands directly in --install-location. Stage a dir that CONTAINS
  MaxHole.driver/ and use that as --root, else HAL gets HAL/Contents/.
- **BlackHole 2Sink devices are NOT isolated** (hit 2026-11-12, P1): upstream
  BlackHole.c shares ONE gRingBuffer, ONE zero-time-stamp clock and ONE
  lastOutputSampleTime/isBufferClear state across Device+Device2 —
  DoIOOperation/GetZeroTimeStamp `#pragma unused(inDeviceObjectID)`. Two live
  sinks cross-talk (breaks V-3). MaxHole fork fixes this with per-device
  arrays (device_index() helper); keep the fix on any rebase.
- **No full Xcode needed for the HAL driver**: plain `clang -bundle` works —
  link -framework CoreAudio -framework AudioToolbox -framework CoreFoundation
  -framework Accelerate (CLT-only machine verified). The upstream .xcodeproj is
  just a wrapper around the same single .c file.
- Fresh machine: github.com may be missing from ~/.ssh/known_hosts —
  ssh-keyscan + check against GitHub's published ED25519 fingerprint
  (SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU), then append.

## Handoff (2026-11-12, session cut-over)
State: research COMPLETE, plan approved, NOTHING built yet on either machine.
- ai server (this Hermes) owns: **P0 plexpipe** (not started) — next session
  starts with: run P0 per this doc; the door URL will be appended here.
- code-m2 Hermes owns: P-1, P1, P2, P3. Kickoff prompt the owner pastes:
  "Clone https://github.com/dark5un/ai-lab-quadlets into
  ~/workspace/github.com/dark5un/ai-lab-quadlets (private repo — if this
  machine has no credentials, stop and ask). Read
  docs/mac-virtual-devices-plan.md end to end; it is the contract. Execute
  MaxPresence phases P-1 then P1 on THIS machine (you are the stepping-stone
  Mac). P2+ only after P1 gates pass. plexpipe (P0) is owned by the ai
  server Hermes; the door URL arrives in this doc. Commit locally, do NOT
  push to main. New pitfalls you hit: append to this doc in your commit.
  Ask before sudo/installer steps."
- CDP/Playwright Meet route: fallback only (Google guest-gate anti-abuse
  flapping — see fact #79 and apps/max-call/ git log); hardened and committed.
- Housekeeping: validation_results.json untracked (meeting codes); old
  versions linger in private-repo history — ephemeral codes, accepted risk.

## Server endpoints inventory (for the brief)
- personaplex :8998 loopback (wss door :8456 exists today)
- max-bridge :8990 loopback (needs door in P4 option b)
- plexpipe :8991 loopback (new; door assigned at P0)
- apps/max-call = CDP fallback route, keep, don't extend.
