# MAX Camera (P2) — scaffold (2026-11-12, feed decision UPDATED same day)

**Feed decision (owner, 2026-11-12): the extension dials the server ITSELF**
(P2 option 2, extension-as-WSS-client). The App Group mailbox design below
is demoted to FALLBACK (maxaudiod --mailbox still implements it).
Supporting server work is DONE: plexpipe per-role door (repo commit
b271630) DEPLOYED + VERIFIED on the ai server — audio leg and video leg
open concurrently (one Mac per role); video leg gets stat heartbeats and
binary 'V' = one complete JPEG per frame; while the real renderer lands,
the client toggles an ffmpeg testsrc feed via {"t":"testvideo","on":true}.
Live proof 2026-11-12: 309 valid 640x480 JPEGs in 10 s (~31 fps) alongside
the running audio bridge.

## Layout
- `host/`   — MaxCamHost app sources (activation requests only; NOT a
  frame pump — the extension self-dials; XPC leg corrected away in V-1).
- `ext/`    — MaxCamExtension sources:
  - MaxCamProvider.swift      — CMIOExtensionProvider/device/stream wiring
  - MaxCamStreamSource.swift  — 30 fps pump: latest 'V' JPEG -> BGRA -> CMSampleBuffer
  - FrameClient.swift         — WSS video-leg client; door URL from App
    Group config.json {"door":"wss://<tailnet-host>:8457"} (dev default
    baked in), hello caps=["video"], testvideo auto-on, 1 s retry loop.
- `*.entitlements` — applied to the Xcode targets; ext has
  com.apple.security.network.client (REQUIRED for the self-dial).
- Sources are v0 SKELETONS: first real compile is inside the Xcode
  template project; expect symbol-level fixes.

## Build procedure
0. DONE (2026-11-12): owner registered Apple ID + dev certificate in Xcode
   (was 0 identities pre-switch). Free-team vs system-extension entitlement:
   answered empirically at activation step 4.
1. OWNER: Xcode ▸ New Project ▸ macOS App "MaxCamHost" (Swift, AppKit) at
   mac/maxcam/MaxCamHost/; then Add Target ▸ System Extensions ▸ **Camera
   Extension** "MaxCamExtension", embedded in app.
2. AGENT: paste our sources over the template; App Group on BOTH targets:
   $(TeamIdentifierPrefix)io.onlyascii.maxpresence (must be team-prefixed
   or validation fails); confirm template plist carries
   CMIOExtensionMachServiceName + host NSSystemExtensionUsageDescription.
3. (FALLBACK only) mailbox path: run-bridge.sh + maxaudiod --mailbox
   ~/Library/Group\ Containers/<TEAMID>.io.onlyascii.maxpresence/mailbox —
   non-sandboxed writer, extension reads group container. Verify only if
   the WSS self-dial is ever blocked.
4. Build + run from /Applications (ditto post-action per contract pitfall):
   `xcodebuild -scheme MaxCamHost -allowProvisioningUpdates build` ->
   launch app -> Activate -> approve: System Settings ▸ General ▸
   Login Items & Extensions ▸ Camera Extensions (NOT Privacy & Security —
   doc drift since WWDC22). `systemextensionsctl list` -> [activated].
5. GATE ladder:
   B1 plumbing: QuickTime ▸ New Movie Recording ▸ "MAX Camera" shows the
      moving testsrc pattern (proves door->extension->CMIO->consumer app).
   B2 P2 gate: QuickTime shows Max ANIMATING — needs the real server
      renderer to replace testsrc (server-side task; candidate for ai
      Hermes delegation over A2A once inbound is enabled on both sides).
   Chrome/Meet for P3: FULL browser restart after activation (enumeration
   at launch, P1 pitfall).
SIP stays ENABLED throughout; if signature checks fail, escalate one
documented relaxation at a time (systemextensionsctl developer on relaxes
ONLY the /Applications location check).

## Open questions (tracked in contract)
- un-notarized dev-signed extension with SIP on: expect YES (docs only
  describe the notarization bypass via SIP-off), verify empirically.
- does the CMIO extension (role user _cmiodalassistants) reach the
  tailnet (MagicDNS resolution + URLSession under sandbox): verify at B1.
- do running apps enumerate the new camera without relaunch: assume NO
  for Chrome; QuickTime may need relaunch.
