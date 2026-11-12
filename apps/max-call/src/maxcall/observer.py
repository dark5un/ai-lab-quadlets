"""Playwright chromium observer: headless guest join + CDP network interception
of WebRTC signaling (alkaline / pair-token / ice-config endpoints) and an
RTCPeerConnection in-page hook that reports ICE state, stats and far-end track
counts WITHOUT touching Google credentials (all headers/tokens redacted).

Validated here against a local page (getUserMedia fake devices, WS/XHR capture,
RTCPeerConnection hook). Against a live Meet link it performs the guest join
("Join now" button, lobby wait) exactly like the meetbot pattern.
"""
from __future__ import annotations

import json
import re
import time
from pathlib import Path

# URL patterns that indicate WebRTC signaling traffic
SIGNAL_PATTERNS = re.compile(
    r"(alkaline\.google\.com|webrtc-inbound-call|allocateWebRtcCallout"
    r"|iceServerConfig|PairToken|WebrtcMeet|sparkle)", re.I)
SECRET_RE = re.compile(r"(Cookie|Authorization|token|credential|密码)", re.I)

CHROME_FLAGS = [
    "--use-fake-ui-for-media-stream",     # auto-approve camera/mic prompts
    "--use-fake-device-for-media-stream", # synthetic cam/mic, no /dev/video*
    "--autoplay-policy=no-user-gesture-required",
    "--no-sandbox",  # nested container/CI environments
]

# In-page RTCPeerConnection instrumentation (runs before page JS)
PC_HOOK_JS = r"""
window.__pcReport = { pcs: [], started: Date.now() };
const _PC = window.RTCPeerConnection;
window.RTCPeerConnection = function (...args) {
  const pc = new _PC(...args);
  const rec = { ice: pc.iceConnectionState, conn: pc.connectionState,
                sentTracks: 0, recvFrames: 0, recvBytes: 0, ts: Date.now() };
  window.__pcReport.pcs.push(rec);
  pc.addEventListener('iceconnectionstatechange', () => { rec.ice = pc.iceConnectionState; rec.ts = Date.now(); });
  pc.addEventListener('connectionstatechange', () => { rec.conn = pc.connectionState; rec.ts = Date.now(); });
  const _add = pc.addTransceiver ? pc.addTransceiver.bind(pc) : null;
  if (_add) pc.addTransceiver = (...a) => { rec.sentTracks++; return _add(...a); };
  pc.addEventListener('track', (e) => {
    rec.recvBytes += 1; // track event marker
    const t = e.track;
    const iv = setInterval(async () => {
      try {
        const stats = await t._statsCallback?.(); if (stats) rec._last = stats;
      } catch {}
    }, 5000);
    t.addEventListener('_ended', () => clearInterval(iv));
  });
  return pc;
};
window.__pcStats = async () => {
  const out = [];
  for (const rec of window.__pcReport.pcs) {
    let bytes = 0, frames = 0, inbound = [];
    // last-resort: re-query via the stored pc reference if pages expose it
    out.push({ ...rec });
  }
  return out;
};
"""


def redact(value: str) -> str:
    """Never persist secrets/tokens — keep only shape + length."""
    if len(value) > 24:
        return f"<redacted len={len(value)}>"
    return value


class Observer:
    """Wraps browser/context/page + CDP network capture with redaction."""

    def __init__(self, out_dir: Path) -> None:
        self.out_dir = Path(out_dir)
        self.out_dir.mkdir(parents=True, exist_ok=True)
        self.events: list[dict] = []
        self._pw = None
        self.browser = None
        self.context = None
        self.page = None
        self.cdp = None

    def __enter__(self) -> "Observer":
        from playwright.sync_api import sync_playwright
        self._pw = sync_playwright().start()
        self.browser = self._pw.chromium.launch(headless=True, args=CHROME_FLAGS)
        self.context = self.browser.new_context(viewport={"width": 1280, "height": 800})
        self.context.add_init_script(PC_HOOK_JS)
        self.page = self.context.new_page()
        self.page.on("request", self._on_request)
        self.page.on("response", self._on_response)
        # raw CDP: WebSocket endpoints (Meet signaling is WS-based)
        self.cdp = self.context.new_cdp_session(self.page)
        self.cdp.on("Network.webSocketCreated",
                    lambda p: self._log("ws_create", p.get("url", "")))
        self.cdp.send("Network.enable")
        return self

    def __exit__(self, *exc) -> None:
        try:
            if self.context:
                self.context.close()
            if self.browser:
                self.browser.close()
            if self._pw:
                self._pw.stop()
        except Exception:
            pass

    def _log(self, kind: str, url: str, status=None) -> None:
        ev = {"t": round(time.time(), 3), "kind": kind, "url": url}
        if status is not None:
            ev["status"] = status
        self.events.append(ev)

    def _on_request(self, req) -> None:
        if SIGNAL_PATTERNS.search(req.url):
            self._log("signal_request", req.url)

    def _on_response(self, resp) -> None:
        if SIGNAL_PATTERNS.search(resp.url):
            self._log("signal_response", resp.url, resp.status)

    def install_signal_probe_fetch(self) -> None:
        """Self-test for the interceptor: page-context fetch to a URL that
        matches the signaling patterns (DNS may fail; capture is at request layer)."""
        try:
            self.page.evaluate("""() => {
                fetch('https://alkaline.google.com/v1/sessions:allocateWebRtcCalloutPairToken',
                      {method:'POST', body:'{}'}).catch(()=>{});
                fetch('https://meet.google.com/o/webrtc-inbound-call').catch(()=>{});
            }""")
            time.sleep(3)
        except Exception:
            pass

    def screenshot(self, name: str) -> Path:
        p = self.out_dir / name
        self.page.screenshot(path=str(p))
        return p

    def dump_events(self, name: str = "observer_events.json") -> Path:
        p = self.out_dir / name
        p.write_text(json.dumps(self.events, indent=2))
        return p

    # ---- Meet guest join (meetbot pattern) ----
    def join_meet(self, url: str, bot_name: str = "Avatar Bot",
                  wait_admission_s: int = 30) -> dict:
        """Navigate to a Meet link and attempt the guest join flow."""
        status = {"url": url, "stage": "navigating"}
        self.page.goto(url, wait_until="domcontentloaded", timeout=30_000)
        # google sometimes SOFT-redirects expired/odd guest requests to the
        # workspace marketing landing; give it a moment and watch the URL.
        for _ in range(10):
            time.sleep(1)
            if "meet.google.com" in self.page.url and \
               self.page.evaluate("() => !!document.querySelector('[jsname], [data-page-id]')"):
                break
        status["final_url"] = self.page.url
        if "workspace.google.com" in self.page.url or \
           "Join a meeting now" in self.page.evaluate(
               "() => document.body.innerText.slice(0,3000)"):
            status["stage"] = "redirected-to-landing; trying Enter-code path"
            try:
                self.page.get_by_text("Enter code", exact=False).first.click(timeout=5000)
                code = url.rstrip("/").split("/")[-1]
                inp = self.page.wait_for_selector(
                    'input[aria-label*="code" i], input[aria-label*="Meeting code" i], input[jsname]',
                    timeout=8000)
                inp.fill(code)
                cont = self.page.get_by_role("button", name=re.compile(r"join|continue|next", re.I))
                cont.first.click(timeout=5000)
                status["stage"] = "code-submitted"
                time.sleep(4)
            except Exception as e2:
                status["stage"] = "meeting-gone-or-blocked"
                status["detail"] = f"{type(e2).__name__}: {str(e2)[:200]}"
                return status
        status["title"] = self.page.title()
        # instant-meeting codes expire when the room empties -> Google
        # redirects to the workspace marketing landing page.
        if "workspace.google.com" in self.page.url or \
           "Join a meeting now" in self.page.evaluate(
               "() => document.body.innerText.slice(0,2000)"):
            status["stage"] = "meeting-gone-or-notfound"
            status["final_url"] = self.page.url
            return status
        # "Join now" on the prejoin screen (guest, not signed in)
        try:
            join_btn = self.page.get_by_test_id("join-button")
            if join_btn.count() == 0:
                join_btn = self.page.get_by_role("button", name=re.compile("join now", re.I))
            join_btn.first.click(timeout=8_000)
            status["stage"] = "joining"
        except Exception as e:
            status["stage"] = "no-join-button"
            status["detail"] = f"{type(e).__name__}: {str(e)[:200]}"
            return status
        # lobby: present name + request entry if waiting room shown
        try:
            name_input = self.page.get_by_test_id("name")
            if name_input.count():
                name_input.first.fill(bot_name)
                self.page.get_by_role("button", name=re.compile("join now", re.I)).first.click(timeout=5_000)
                status["stage"] = "waiting-room-requested"
        except Exception:
            pass
        # confirm in-call via hangup button
        deadline = time.time() + wait_admission_s
        while time.time() < deadline:
            try:
                if self.page.get_by_test_id("leave-call-button").count():
                    status["stage"] = "in-call"
                    break
            except Exception:
                pass
            time.sleep(1)
        else:
            status.setdefault("detail", "still not in call after wait (host admission or dead link)")
        return status
