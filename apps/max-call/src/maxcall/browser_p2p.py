"""Interop validation: Playwright Chromium (fake cam/mic flags) <-> aiortc
avatar over loopback WebRTC, with a tiny stdlib HTTP signaling server.

Proves end-to-end, without Google:
 - Chromium headless gets getUserMedia fake devices (no /dev/video*)
 - real browser RTCPeerConnection negotiates with our aiortc session
   (DTLS-SRTP interop, VP8+Opus both directions)
 - aiortc sends the synthetic test pattern, browser counts received video
   frames/sec (window.__vfcCount via requestVideoFrameCallback)
 - browser sends its fake-camera stream, aiortc counts frames/sec
"""
from __future__ import annotations

import asyncio
import json
import sys
import threading
import time
from functools import partial
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from aiortc import RTCPeerConnection, RTCSessionDescription  # noqa: E402
from maxcall.tracks import SineAudioTrack, TestPatternVideoTrack  # noqa: E402

PAGE_HTML = """<!doctype html><meta charset=utf-8><title>max-call interop</title>
<body style="margin:0;background:#111">
<video id=v autoplay muted playsinline style="width:640px;height:480px"></video>
<script>
window.__state = {stage: 'init', vfcCount: 0, gum: null, ice: null, conn: null};
(async () => {
  try {
    const stream = await navigator.mediaDevices.getUserMedia({video: true, audio: true});
    window.__state.gum = stream.getTracks().map(t => t.kind + ':' + t.label);
    const pc = new RTCPeerConnection();
    stream.getTracks().forEach(t => pc.addTrack(t, stream));
    pc.addTransceiver('video', {direction: 'recvonly'});
    pc.addTransceiver('audio', {direction: 'recvonly'});
    pc.oniceconnectionstatechange = () => window.__state.ice = pc.iceConnectionState;
    pc.onconnectionstatechange = () => window.__state.conn = pc.connectionState;
    pc.ontrack = (e) => { window.__pc = pc; window.__state.tracks = (window.__state.tracks||[]).concat(e.track.kind);
      if (e.track.kind === 'video') document.getElementById('v').srcObject = e.streams[0]; };
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    const r = await fetch('/offer', {method: 'POST', body: JSON.stringify({sdp: offer.sdp, type: offer.type})});
    const answer = await r.json();
    await pc.setRemoteDescription(answer);
    window.__state.stage = 'negotiated';
  } catch (err) { window.__state.stage = 'error: ' + err; }
})();
</script>"""


class Signaler:
    def __init__(self) -> None:
        self.answer: dict | None = None
        self.received = {"video": 0, "audio": 0}
        self.pc = RTCPeerConnection()
        self.pc.addTrack(TestPatternVideoTrack())
        self.pc.addTrack(SineAudioTrack())

        @self.pc.on("track")
        def _on_track(track):
            async def drain():
                try:
                    while True:
                        await track.recv()
                        self.received[track.kind] += 1
                except Exception:
                    pass
            asyncio.ensure_future(drain())

        async def handle_offer(sdp: str, sdp_type: str) -> dict:
            loop = asyncio.get_event_loop()
            await asyncio.run_coroutine_threadsafe(self._negotiate(sdp, sdp_type), loop)
            return self.answer

        self._loop = None
        self.handle_offer = handle_offer

    async def _negotiate(self, sdp: str, sdp_type: str) -> None:
        await self.pc.setRemoteDescription(RTCSessionDescription(sdp=sdp, type=sdp_type))
        await self.pc.setLocalDescription(await self.pc.createAnswer())
        # use localDescription (post-ICE-gather); createAnswer's SDP has no candidates
        self.answer = {"sdp": self.pc.localDescription.sdp,
                       "type": self.pc.localDescription.type}


class Handler(BaseHTTPRequestHandler):
    def __init__(self, sig: Signaler, *a, **kw):
        self.sig = sig
        super().__init__(*a, **kw)

    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path == "/":
            body = PAGE_HTML.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path == "/offer":
            n = int(self.headers.get("Content-Length", 0))
            payload = json.loads(self.rfile.read(n))
            fut = asyncio.run_coroutine_threadsafe(
                self.sig._negotiate(payload["sdp"], payload["type"]), self.sig._loop)
            fut.result(timeout=10)
            body = json.dumps(self.sig.answer).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()


def main() -> int:
    from playwright.sync_api import sync_playwright
    hold_s = float(sys.argv[1]) if len(sys.argv) > 1 else 10.0

    loop = asyncio.new_event_loop()
    threading.Thread(target=loop.run_forever, daemon=True).start()

    # IMPORTANT: RTCPeerConnection must be created INSIDE the loop thread —
    # aiortc captures the current event loop at construction; creating it on
    # another thread causes "Future attached to a different loop" in senders.
    async def _mk():
        return Signaler()
    sig = asyncio.run_coroutine_threadsafe(_mk(), loop).result()
    sig._loop = loop
    httpd = HTTPServer(("127.0.0.1", 0), partial(Handler, sig))
    port = httpd.server_address[1]
    threading.Thread(target=httpd.serve_forever, daemon=True).start()

    from maxcall.observer import CHROME_FLAGS
    result = {"server": f"http://127.0.0.1:{port}"}
    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=True, args=CHROME_FLAGS)
        page = browser.new_page()
        page.goto(f"http://127.0.0.1:{port}/", wait_until="load")
        t0 = time.monotonic()
        while time.monotonic() - t0 < hold_s:
            time.sleep(1)
        state = page.evaluate("window.__state")
        result["browser"] = state
        # authoritative decode counters from the browser's WebRTC stack
        result["browser_inbound_stats"] = page.evaluate("""async () => {
            if (!window.__pc) return [];
            const s = await window.__pc.getStats();
            return [...s.values()].filter(r => r.type === 'inbound-rtp').map(r =>
              ({kind: r.kind, bytes: r.bytesReceived, packets: r.packetsReceived,
                framesDecoded: r.framesDecoded ?? null}));
        }""")
        try:
            result["browser_pc_debug"] = page.evaluate("""() => window.__pc ? {
                gathering: window.__pc.iceGatheringState,
                signaling: window.__pc.signalingState,
                localCands: (window.__pc.localDescription?.sdp.match(/a=candidate:.*/g)||[]).slice(0,6),
                remoteCands: (window.__pc.remoteDescription?.sdp.match(/a=candidate:.*/g)||[]).slice(0,6),
            } : null""")
        except Exception as e:
            result["browser_pc_debug"] = str(e)
        result["ice_pc"] = {"aiortc_connection": sig.pc.connectionState,
                            "aiortc_ice": sig.pc.iceConnectionState}
        asyncio.run_coroutine_threadsafe(_collect(sig), loop).result(timeout=5)
        result["aiortc_received"] = dict(sig.received)
        shot = Path(__file__).resolve().parent.parent.parent / "artifacts" / "interop_browser_page.png"
        shot.parent.mkdir(parents=True, exist_ok=True)
        page.screenshot(path=str(shot))
        result["screenshot"] = str(shot)
        asyncio.run_coroutine_threadsafe(sig.pc.close(), loop).result(timeout=5)
        browser.close()
    httpd.shutdown()
    vdec = next((r["framesDecoded"] or 0 for r in result["browser_inbound_stats"]
                 if r["kind"] == "video"), 0)
    vbytes = next((r["bytes"] or 0 for r in result["browser_inbound_stats"]
                   if r["kind"] == "video"), 0)
    abytes = next((r["bytes"] or 0 for r in result["browser_inbound_stats"]
                   if r["kind"] == "audio"), 0)
    result["video_frames_browser_decoded"] = vdec
    result["video_fps_browser_recv"] = round(vdec / hold_s, 2)
    afps = round(result["aiortc_received"]["video"] / hold_s, 2)
    result["video_fps_aiortc_recv"] = afps
    result["bitrate_browser_recv_vbps"] = round(vbytes * 8 / hold_s)
    print(json.dumps(result, indent=2))
    ok = (result["browser"]["conn"] == "connected" and vdec > 3 and afps > 1
          and result["browser"]["gum"] and abytes > 1000)
    print("PASS" if ok else "FAIL", file=sys.stderr)
    return 0 if ok else 1


async def _collect(sig):
    # drain scheduler; counters updated by recv tasks
    await asyncio.sleep(0.1)


if __name__ == "__main__":
    sys.exit(main())
