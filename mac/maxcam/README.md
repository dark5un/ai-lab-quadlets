# MAX Camera (P2) — scaffold (2026-11-12)

Decision (owner, 2026-11-12): frame feed = **App Group mailbox**.
maxaudiod receives JPEG 'V' frames from plexpipe already (was discarding
them); with --mailbox DIR it writes each frame atomically (tmp+rename) to
DIR/frame.jpg. The Camera Extension watches the shared App Group container
and feeds latest frames into its CMIO source stream. maxaudiod stays the
ONLY door client -> zero server/protocol changes. P4 may revisit
extension-as-its-own-client (needs plexpipe multi-session first).

## Layout
- `host/`   — MaxCamHost app sources (activation requests only; it is NOT
  a frame pump — mailbox replaced the XPC leg, see contract V-1 correction).
- `ext/`    — MaxCamExtension sources (provider + device + stream +
  mailbox reader).
- `*.entitlements` — to be applied to the Xcode targets.
- `Info.plist.notes.md` — required plist keys the template must carry.

## Build procedure (first time)
0. OWNER (Xcode GUI): Settings ▸ Accounts ▸ add Apple ID (free personal
   team). THIS answers build-day question #1: whether the system-extension
   install entitlement is granted/validated without paid membership.
   Before that, `security find-identity -v -p codesigning` = 0 identities.
1. OWNER: Xcode ▸ New Project ▸ macOS App "MaxCamHost" (Swift, AppKit)
   at mac/maxcam/MaxCamHost/; then Target ▸ Add Target ▸ System Extensions
   ▸ **Camera Extension** "MaxCamExtension", embedded in app.
2. AGENT: replace template sources with the ones here (they keep template
   symbol names where the template defines them); set App Group on both
   targets: $(TeamIdentifierPrefix)io.onlyascii.maxpresence — app-group id
   must be prefixed by team id (Apple doc: creating-a-camera-extension).
3. AGENT: maxaudiod writer side (done here: --mailbox flag); after the app
   group exists, container path =
   ~/Library/Group Containers/<TEAMID>.io.onlyascii.maxpresence/mailbox/
   — non-sandboxed processes may read/write it; VERIFY at first run (if
   TCC blocks the plain path, mailbox dir falls back to a dir passed via
   --mailbox and the extension reads it via security-scoped bookmark —
   LAST resort documented, not default).
4. Build + run from /Applications (ditto post-action per contract pitfall):
   xcodebuild -scheme MaxCamHost -allowProvisioningUpdates build
   -> launch app -> activationRequest -> approve: System Settings ▸
   General ▸ Login Items & Extensions ▸ Camera Extensions (NOT Privacy &
   Security — doc drift since WWDC22).
5. GATE (contract P2): QuickTime ▸ New Movie Recording ▸ camera picker
   shows "MAX Camera" ▸ shows Max animating (feed maxaudiod from a live
   call or a recorded 'V' stream). Verify with `systemextensionsctl list`
   showing [activated].
SIP stays ENABLED throughout; if signature checks fail, escalate one
documented relaxation at a time (systemextensionsctl developer on relaxes
only the /Applications location check).

## Open questions (tracked in contract)
- free team + entitlement validity (step 0 resolves)
- un-notarized dev-signed extension with SIP on: expect YES (docs only
  describe notarization bypass via SIP-off), verify empirically.
- do running apps enumerate the new camera without relaunch: assume NO
  for Chrome (P1 pitfall: enumerate at launch); QuickTime may need relaunch.
