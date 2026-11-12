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
from mini-m4 (mini-m4 stays the rerank/MLX inference node). On the known
tailnet (IP deliberately not committed; `tailscale status` on ai lists it),
user panos@, currently NO ssh from ai (port 22 refused —
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
  (framing = apps/max-headroom/src/plex-client.js; the proven
  python mirror = duplex-bus bus/fdb_personaplex.py); plex reply
  audio -> fan out: (1) downlink 'A' to Mac, (2) max-bridge /feed (lips).
  Bridge /shapes frames -> downlink (option b) or server-render -> 'V'.
  STAT heartbeat payload (consumed by Mac status-bar widget, owner ask
  2026-11-12 — every ~2 s while the session is open):
    {"t":"stat","session_s":float,"up_bytes":int,"down_bytes":int,
     "up_frames":int,"down_frames":int,"video_frames":int,
     "plex_up":bool,"bridge_up":bool}
  Link-active = ws open + stat arriving; "healthy" = plex_up && bridge_up.
  MAXBar note (2026-11-12): IMPLEMENTED same day (mac-maxpresence) —
  maxaudiod passes stat plex_up/bridge_up (+server frame counters) into its
  local heartbeat json; maxbar renders "server: plex ✓ bridge ✓" on the link
  line and a 4th dot colour (yellow = door connected, server brain down /
  stat stale). Unit-verified with stat frames fed through Bridge.reader()
  without opening any audio stream.
  Also S->C {"t":"caption","text":...} (plex 0x02 monologue stream) and
  S->C {"t":"bye","reason":"busy"} when a second session tries to connect.
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

MAC BUILD NOTES (as actually built, 2026-11-12 — frozen facts for P1 tests):
- Sources: `mac/maxhole/` (BlackHole 0.7.1 @ 6008d295 fork; UPSTREAM.md lists
  deltas) + `mac/maxaudiod/` (uv python prototype).
- Installed on code-m2: `/Library/Audio/Plug-Ins/HAL/MaxHole.driver`,
  bundle-id `io.onlyascii.maxhole`, ad-hoc signed, loaded OK on macOS 27.2.
- Device names are exactly **"MAX Mic"** and **"MAX Out"** (2ch each,
  48000+24000 Hz, kLatency_Frame_Size=512). Volume/mute/clock-source/
  sample-rate are GLOBAL across the two devices; ring buffer + IO clocks are
  per-device (fork fix, see pitfalls).
- maxaudiod: `loopback-test` = owner-run gate (agent must NOT open input
  streams — owner policy 2026-11-12); `run --door WSS_URL` = bridge mode,
  uplink s16le 48k mono 'A' frames, downlink 'A' 24k played natively (no
  resampler on Mac), JSON hello/stat, capped reconnect backoff, 'V' ignored
  until P2. Since 2026-11-12 maxaudiod also writes a 2 s heartbeat JSON to
  ~/Library/Application Support/MaxPresence/maxaudiod.json (schema in
  mac/maxbar/README.md) — consumed by MAXBar; future hosts (MaxCamHost)
  drop same-schema files in that dir.
  CONTROL channel (2026-11-12, owner ask): widget/owner may write
  cmd-maxaudiod.json {"link":"up|down","mute_mic":bool,"mute_uplink":bool};
  maxaudiod polls it every heartbeat — link-down drops the socket and idles
  (frees plexpipe session slot), mic-mute drains downlink without playing
  (MAX Mic -> silence for the meeting), uplink-mute zeroes capture (plex
  deaf). Daemon echoes state in heartbeat (link_requested/mic_muted/
  uplink_muted). MaxCamHost P2 contract: cmd-maxcamhost.json {"mute":bool}.
  Verified live end-to-end (down/up/mutes/reset), incl. auto-reconnect
  after backoff. cmd-* files must be excluded from daemon enumeration.
- maxagg (`mac/maxagg/`): CLI for the two aggregate devices the Meet gate
  needs: "MAX Mix In" (built-in mic FIRST + MAX Mic, plain concat in=[1+2])
  = one mic input for both you and Max; "MAX Multi Out" (stacked=1,
  out=[2+2] fan-out) = meeting audio to speakers AND MAX Out. Verified by
  per-buffer channel maps; destroy via `maxagg destroy NAME`.
- MAXBar (`mac/maxbar/`): Swift/AppKit menu-bar widget (CLT swiftc build,
  ad-hoc signed, LSUIElement) showing link state (heartbeat), MAX Mic/Out
  installed+STREAMING (CoreAudio 'gone'; 'sact' is static 1 on MaxHole —
  useless), MAX Camera present+streaming (CMIO, lights up at P2). Read-only:
  opens no streams → no TCC prompt. Self-checks its own capability each poll
  (needs NO rights today; failure would show ⚠ + named gate in the menu).
  Installed ~/Applications/MAXBar.app.

## Phases
- P-1 CODE-M2 ENV (Mac Hermes): sw_vers / chip / brew / Xcode CLT presence;
  tailscale status (must see ai); decide Remote Login on/off for cross-
  debugging; create a private dir for the MaxPresence sources.
  STATUS 2026-11-12 (code-m2): **done** — macOS 27.2 / M2 Max / brew 7.0.13 /
  Xcode CLT active dir (UPDATE P2-prep 2026-11-12: Xcode.app 27.2 found
  installed in /Applications, 3.7G on disk, never activated — `sudo
  xcode-select -s /Applications/Xcode.app/Contents/Developer` is the
  owner-run switch needed before P2 builds; verify xcodebuild -version
  after); tailscale peer
  `ai` peer live (tailnet IP not committed); Remote Login kept OFF (work is local); sources
  in this private repo under `mac/` (branch mac-maxpresence, merged to main
  per owner).
- P0 SERVER: implement plexpipe + door + protocol doc; loop-test with a
  python client (no Mac): feed recorded speech -> hear plex reply downlink
  + bridge lip animation. GATE: round-trip audio < 1 s.
  STATUS 2026-11-12 (ai): **DONE** — containers/plexpipe/ (python,
  websockets+sphn+ffmpeg), quadlet plexpipe.container (avatar group,
  boot=false), door `tailscale serve --bg --https=8457 -> 127.0.0.1:8991`
  (wss handshake + stat round-trip verified through TLS). Loop test
  (benchdata/v1.0 candor sample, 6-27 s): uplink 'A' 48k -> plex_up +
  bridge_up both true; downlink 'A' 24k flows at exact real-time cadence
  (99 frames ~= 7.9 s audio over 12 s session); first backchannel packet
  ~0.7 s after uplink audio reaches plex; bridge /shapes animated with
  JawOpen 0.61 / MouthRollUpper 0.70 peaks. Model turn DECISION time varies
  (personaplex full-duplex sampling); pipeline overhead itself stays well
  under 1 s (80 ms sphn ticks + streaming ffmpeg resample).
- P1 MAC audio: MaxHole + maxaudiod (python prototype ok). Manual test in
  Meet incognito: Panos' browser mic=MAX Mic, speaker=Multi-Output
  (phones+MAX Out); plexpipe uplink = meeting audio; GATE: Max answers the
  meeting out loud into the call.
  STATUS 2026-11-12 (code-m2): MaxHole 0.1.0 installed + ad-hoc loaded by
  coreaudiod; device-loop gate **PASS** (owner-run `maxaudiod.py
  loopback-test`: both pipes self-loop tone-peak=1.00, cross-leak 0.00 —
  per-device ring-buffer fix confirmed).
  MEET GATE run 1 2026-11-12 (owner, two-participant model): **FAIL — human
  heard no Max in the call**, Mac audio chain exonerated by counters (see
  counter-triage pitfall): link UP all along, uplink tx at exact real-time
  rate (plex heard the human), plex ANSWERED (280 audible downlink frames
  ~= 5.6 s speech, played into MAX Mic, mute flags false), and NO
  self-hearing runaway (gated_frames=0 with half-duplex gate OFF —
  two-participant topology validated live). Break is inside the incognito
  Meet session: mic not really on "MAX Mic", private-window mic permission,
  or Meet noise suppression squashing the synthetic voice. Gate stays
  PENDING until a PASS run (triage checklist in the runbook).
  RUN 2 2026-11-12 (same call, live counters): browser-fault theory RETIRED
  — owner DID hear one real answer + backchannels, so MAX Mic->Meet->mix
  works end-to-end. New fault: after a few turns plex runs ~10 audible
  frames/s CONTINUOUSLY with no human speech + gibberish/multilingual drift
  = the self-hearing symptom again, via the ACOUSTIC path (Max -> human
  speakers -> human built-in mic -> human uplink -> meeting mix -> MAX Out
  -> plex hears itself ~300 ms late). Chrome AEC does not reliably cancel
  synthetic voice through laptop speakers — consequence (b) below is
  optimistic. P1 gate runs REQUIRE human-side headphones (or maxaudiod
  --gate, which does break this cycle: 300 ms echo << 1.2 s hold).
- P2 MAC video: MaxCamHost+MaxCamExtension, JPEG 'V' path. GATE: QuickTime
  shows MAX Camera with Max animating (server-rendered).
  PREP 2026-11-12: BLOCKED on P1 Meet gate PASS first (kickoff contract).
  Prereq: full Xcode — Xcode.app 27.2 is already on disk (see P-1 update);
  needs the owner-run `sudo xcode-select -s` switch, then `xcodebuild
  -version` sanity + first probe of Camera Extension build/sign/enable
  path (System Settings > Privacy & Security > Camera Extensions; whether
  ad-hoc signing suffices locally or a dev policy profile is needed is an
  OPEN question — verify against Apple docs before building, WWDC22 10022).
  maxaudiod currently ignores 'V' frames (reader: tag==b'V' -> pass); P2
  adds the MaxCamHost consumer + XPC leg to the extension.
- P3 FULL JOIN: incognito Meet with MAX Cam + MAX Mic: 10-minute
  conversation; GATE: speech-to-motion latency <= 450 ms measured, no echo,
  no artifacts.
- P4 POLISH: option (b) local rendering (shapes over WSS -> Metal offscreen
  three.js), launchd orchestration one-click "go live", idle/speaking
  states, maybe VP8 instead of JPEG.

## Pitfalls (paid for already — hand to Mac Hermes verbatim)
- **personaplex is SINGLE-SESSION**: one global `async with self.lock` — any
  live client (the max-headroom browser app's GO LIVE tab included) makes
  every other dial hang before the handshake. FREE the plex before P1/P3
  gates on the Mac. Also: a client socket leaked on cancel wedges the lock
  forever — plexpipe now closes its plex leg with asyncio.shield in finally
  (hit live 2026-11-12 during P0 testing).
- **personaplex container stdout is block-buffered** — 'Incoming connection'
  lines appear minutes late; don't diagnose liveness from its logs in real
  time (ask plexpipe's own journal: 'plex streaming').
- **sphn 0.2.x REDESIGNED the Opus stream API** (OpusStreamWriter lost
  read_bytes / OpusStreamReader lost read_pcm): pin **sphn==0.1.12** — the
  version personaplex's own fork server.py and the duplex-bus fdb harness
  run against (verified live 2026-11-12).
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
- **Aggregates (2026-11-12, measured + wiki-confirmed)**: AudioHardwareCreateAggregateDevice
  REQUIRES top-level "uid" (own persistent id) or returns 'inva'. "stacked":1 =
  multi-output fan-out; absent = plain concat. For MAX Mix In: physical mic
  FIRST — Meet/Chrome use the first two channels; BlackHole/MAX-first ordering
  is the documented Meet failure mode (Google community thread). Meet may still
  pick one channel — if so, fallback = in-driver mixing: anything played into
  MAX Mic is summed in the ring buffer, so a tiny mic->MAX-Mic pump gives a
  true mono mix (needs standing mic consent; decide at P3-echo time).
- **Usage model FIXED by owner 2026-11-12 — TWO-PARTICIPANT topology (was:
  single-session "Max owns the human's mic slot", which is what created the
  self-hearing loop)**: Max joins each meeting as HIS OWN participant — an
  incognito browser session with mic = MAX Mic, camera = MAX Camera (P2),
  speaker = MAX Out. The human keeps built-in mic/camera/speakers on their
  own session. Consequences: (a) Meet never returns a participant's own
  audio to its own output, so plex CANNOT hear Max — DIGITAL loop is
  structurally gone, no mixing aggregates needed (MAX Mix In / MAX Multi Out
  destroyed; maxagg remains only for the single-session variant). BUT an
  ACOUSTIC loop survives: Max's voice out of the HUMAN's speakers into the
  HUMAN's mic re-enters the mix (see acoustic-loop pitfall; headphones or
  --gate mandatory for gate runs). (b) Chrome AEC runs per session against
  that session's own output — it SHOULD cancel Max's echo at the human
  mic, but MEASURED 2026-11-12 it does not reliably cancel synthetic
  voice through laptop speakers — do not trust it, separate paths
  physically. (c) maxaudiod --gate (half-duplex) is OFF by
  default: in this topology it would only kill barge-in (personaplex is
  full-duplex by design). Keep the flag for the single-session fallback.
- **Max hears himself — self-answer runaway loop (2026-11-12, observed live
  in Meet + fixed in maxaudiod)**: Meet re-plays everything it receives,
  including Max's voice from MAX Mic/MAX Mix In; that playback reaches MAX
  Out -> uplink -> plex hears Max -> answers itself (downlink rate climbs
  with no human speech; multilingual model drifts language — owner heard
  "Chinese"). maxaudiod now gates UPLINK for 1.2 s after each *audible*
  downlink frame (energy rms>0.01 — plexpipe pads silence at 12.5-25/s
  real-time, a content-blind gate jams the uplink permanently — measured).
  Verified: runaway decayed to zero new speaking frames; gate never fires
  on silence. Trade-off = half-duplex: humans are muted for ~1.2 s after
  Max speaks; permanent fix is server-side AEC at P4 (plexpipe knows its
  own playback exactly). Interim: owner should use headphones — acoustic
  speaker->built-in-mic echo into MAX Mix In also loops into the meeting.
- **Trailing-dot SNI kills tailscale-serve doors for OpenSSL-family clients
  (2026-11-12, root-caused by byte-level ClientHello capture+replay on ai)**:
  `tailscale status --json` gives peer DNSName WITH a trailing dot
  ("ai.<tailnet>.ts.net."). Feeding that into a wss:// URL makes python/
  OpenSSL send a trailing-dot SNI, which tailscale serve's Go TLS rejects
  with `TLSV1_ALERT_DECODE_ERROR` (tailscaled log: "tls: error decoding
  message"). curl/SecureTransport normalize the dot, so curl probes pass
  while actual clients flap — misleading. maxaudiod now strips a trailing
  dot from the door host (verified live: link UP, stat frames flowing);
  launchd/P4 scripts should pass the plain (dotless) URL anyway.
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
- **Counter-triage localizes "can't hear Max" WITHOUT opening any audio
  stream** (proven 2026-11-12, Meet run 1): diff the heartbeat at
  ~/Library/Application Support/MaxPresence/maxaudiod.json over ~6 s.
  tx climbing at ~50/s = meeting audio IS reaching plex (incognito speaker
  routing to MAX Out is fine). rx ~12.5-25/s with speaking_frames Δ=0 =
  connected-but-silent plex (silence padding). speaking_frames Δ>0 =
  audible plex speech WAS played into MAX Mic (with mute flags false).
  All-green + human deaf => the fault is inside Chrome/Meet (mic device
  selection, private-window mic permission, noise suppression), not Mac
  audio — don't touch the drivers, fix the browser session.
- **Acoustic self-hearing loop survives the two-participant model**
  (hit 2026-11-12, live Meet run 2): Max -> HUMAN speakers -> HUMAN built-in
  mic -> human session uplink -> meeting mix -> incognito session -> MAX Out
  -> plex hears Max ~300 ms late -> self-answers -> ~10 audible downlink
  frames/s continuous with no human speech + gibberish/multilingual drift
  (same symptom class as the old digital loop — signature is enough to
  diagnose). Counter fingerprint: speaking_frames climbing steadily while
  nobody talks; tx stays real-time. Fixes: (1) HUMAN-side headphones —
  mandatory for P1 gate runs, not optional; (2) maxaudiod --gate breaks the
  cycle (echo << 1.2 s hold) at the half-duplex cost — CLI-only flag today,
  runtime toggle via cmd-maxaudiod.json is a small P2-era win; (3) permanent:
  server-side AEC at P4. Mid-call loop-kill = MAXBar "Mute uplink"; NEVER
  kill/restart maxaudiod mid-call (drops the plex session, forces reconnect
  churn + 'rejecting second session' storm while the server still holds the
  dead leg).
- Fresh machine: github.com may be missing from ~/.ssh/known_hosts —
  ssh-keyscan + check against GitHub's published ED25519 fingerprint
  (SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU), then append.

## Handoff (2026-11-12, session cut-over)
State: research COMPLETE, plan approved, NOTHING built yet on either machine.
UPDATE (same day, later, code-m2): Mac side is NOT "nothing" anymore — P-1 done
and P1 device-loop gate PASSED (MaxHole fork + maxaudiod prototype under
`mac/`, merged to main; the P1 *Meet* gate still awaits P0's door URL). Owner
now allows pushing to main for these merges.
- ai server (this Hermes) owns: **P0 plexpipe** — DONE 2026-11-12.
  Door URL (appended per plan): **wss://ai.<tailnet>.ts.net:8457**
  (tailscale serve --https=8457 -> 127.0.0.1:8991; tailnet IP deliberately
  not committed — the Mac is already a peer, resolve via `tailscale status`).
  maxaudiod: `run --door wss://ai.<tailnet>.ts.net:8457`.
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
- plexpipe :8991 loopback (LIVE; tailnet door `tailscale serve --https=8457`,
  assigned at P0 2026-11-12)
- apps/max-call = CDP fallback route, keep, don't extend.
