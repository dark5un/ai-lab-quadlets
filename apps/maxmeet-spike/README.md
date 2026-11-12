# maxmeet-spike — ticket 01 (go/no-go for the whole browser lane)

Minimal unpacked MV3 extension proving the one unproven crux: **does production
Google Meet accept an in-page WebAudio synthetic microphone track** and let a
human peer hear it cleanly (no AEC/NS/AGC mangling)?

What it does on meet.google.com only:
- patches `getUserMedia` → audio: AudioContext→MediaStreamDestination track
  (30 Hz keepalive tone at gain 2e-4 + "This is Max…" voice buffer replayed every
  6 s); video: 640x480 canvas slate (never rAF-driven).
- patches `enumerateDevices` → prepends fake MAX Camera / MAX Microphone
  (Meet disables its controls with no camera enumerated).
- new MediaStream per call; `resume()` on first gUM; label rewrites.
- green/red floating button bottom-left = kill switch (consent gate).

## Test protocol (needs a human — you are the peer)

1. Chrome → `chrome://extensions` → Developer mode → **Load unpacked** →
   pick this folder.
2. Create/use a **second Chrome profile** (fresh, so Meet can't cache anything).
3. In that profile open `meet.google.com`, start a new meeting, join with
   mic+camera — the tile should show the MAX SPIKE slate; bottom-left button
   should read "MAX SPIKE: ON".
4. Join the SAME meeting from your phone or your main browser as the peer.
5. Verify as the peer, in order:
   a. You hear "This is Max…" repeat every ~6 s — clearly, no warbling/gating
      (that would be platform NS/AGC chewing on it).
   b. Meet's audio-level meter on Max's tile moves with the voice.
   c. Toggle Max's mic off/on from the Meet controls — dead vs alive tracks.
   d. Keep the tab hidden 2–3 min — audio must keep flowing.
6. Report the four verdicts (heard? clean? mute ok? hidden ok?) — append them
   under `## Comments` of ticket 01.

Kill criterion (from the spec): if Meet rejects in-page synthetic audio →
fallback decision = HAL-mic-only + browser-vcam-only hybrid (the camera
extension dies either way). Record GO/NO-GO on the ticket.

Not in this spike (deliberately): door client, addTrack patch, reconnect,
identity spoof beyond labels. Those are tickets 02/05.
