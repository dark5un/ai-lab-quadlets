"""maxvid — MaxPresence P2 server video renderer (docs/mac-virtual-devices-plan.md V-6 option a).

Headless chromium (SwiftShader, CPU-only — the 4070 Ti budget is untouched)
renders the max-headroom v2 app at FRAME_W x FRAME_H. The app is fed live
blendshapes from the max-bridge (/ root = /shapes fan-out), which plexpipe
fills while a Mac audio session is open; the app's own rAF loop keeps head
motion / blinks autonomous, so the face is alive even with a stale shape feed.

The built app (apps/max-headroom/dist) is served internally from /web (repo
volume, read-only) so the renderer does not depend on any host dev server.

Frames are grabbed via CDP Page.startScreencast (event-driven: the browser
paints and jpeg-encodes asynchronously; everyNthFrame paces delivery to
~FRAME_FPS) and pushed to subscribers as raw binary JPEG messages on :PORT
/frames.
One subscriber by design: plexpipe, which relays them down the door as
'V' frames. Capture + chromium lifecycle follow demand: chromium starts
when the first subscriber connects and stops when the last leaves.
The newest frame is cached and replayed to a joining subscriber so the
door always has a frame to send immediately.
"""
import asyncio
import base64
import functools
import http.server
import json
import os
import time
import urllib.request

import websockets

PORT = int(os.environ.get("MAXVID_PORT", "8992"))
APP_PORT = int(os.environ.get("MAXVID_APP_PORT", "8620"))
WEB_DIR = os.environ.get("WEB_DIR", "/web")
BRIDGE_URL = os.environ.get("BRIDGE_URL", "ws://systemd-max-bridge:8990")
FRAME_W = int(os.environ.get("FRAME_W", "640"))
FRAME_H = int(os.environ.get("FRAME_H", "480"))
FPS = float(os.environ.get("FRAME_FPS", "30"))
QUALITY = int(os.environ.get("JPEG_QUALITY", "75"))
# screencast hands one frame per N paints (~60/s in headless chromium)
EVERY_NTH = max(1, round(60 / FPS))
CDP_PORT = int(os.environ.get("CHROME_DEBUG_PORT", "9222"))
CHROME_BIN = os.environ.get("CHROME_BIN", "chromium")
RECONNECT_MAX = 15.0
BOOT_TIMEOUT = 30.0

# v2 app, clean camera layout (?nohud=1), blendshapes from the bridge door.
APP_URL = f"http://127.0.0.1:{APP_PORT}/?v2=1&nohud=1&feed=bridge&door={BRIDGE_URL}"


def log(*a):
    print("[maxvid]", *a, flush=True)


class SilentHTTP(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args):  # keep the journal readable
        pass


def serve_web():
    handler = functools.partial(SilentHTTP, directory=WEB_DIR)
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", APP_PORT), handler)
    asyncio.get_running_loop().run_in_executor(None, srv.serve_forever)
    log(f"web root {WEB_DIR} on :{APP_PORT}")
    return srv


class CDP:
    """Minimal CDP client over one websocket: request/response by id,
    events routed to an optional on_event callback."""

    def __init__(self, ws, on_event=None):
        self.ws = ws
        self.on_event = on_event
        self._id = 0
        self._pending = {}
        self.reader = asyncio.create_task(self._route())

    async def _route(self):
        try:
            async for raw in self.ws:
                try:
                    msg = json.loads(raw)
                except (json.JSONDecodeError, TypeError):
                    continue
                if "id" in msg:
                    fut = self._pending.pop(msg["id"], None)
                    if fut is not None and not fut.done():
                        fut.set_result(msg)
                elif self.on_event is not None:
                    try:
                        self.on_event(msg)
                    except Exception:
                        pass
        except Exception:
            for fut in self._pending.values():
                if not fut.done():
                    fut.set_exception(ConnectionError("cdp closed"))
            self._pending.clear()

    async def call(self, method, timeout=15.0, **params):
        self._id += 1
        mid = self._id
        fut = asyncio.get_running_loop().create_future()
        self._pending[mid] = fut
        await self.ws.send(json.dumps({"id": mid, "method": method, "params": params}))
        resp = await asyncio.wait_for(fut, timeout=timeout)
        if "error" in resp:
            raise RuntimeError(f"{method}: {resp['error']}")
        return resp.get("result", {})


class Renderer:
    """One chromium page: launch -> attach CDP -> boot the face -> stream
    screencast frames into on_frame(jpeg)."""

    def __init__(self, on_frame):
        self.on_frame = on_frame
        self.proc = None
        self.cdp = None
        self.last_frame_at = 0.0

    def _on_event(self, msg):
        if msg.get("method") != "Page.screencastFrame" or self.cdp is None:
            return
        p = msg["params"]
        self.last_frame_at = time.monotonic()
        try:
            asyncio.get_running_loop().create_task(
                self.cdp.ws.send(json.dumps(
                    {"id": 0, "method": "Page.screencastFrameAck",
                     "params": {"sessionId": p["sessionId"]}})))
        except Exception:
            pass
        try:
            self.on_frame(base64.b64decode(p["data"]))
        except Exception:
            pass

    async def start(self):
        self.proc = await asyncio.create_subprocess_exec(
            CHROME_BIN,
            "--headless=new",
            "--no-sandbox",
            "--disable-dev-shm-usage",
            # software WebGL via SwiftShader; NEVER touch the NVIDIA cards:
            "--use-gl=angle", "--use-angle=swiftshader",
            "--enable-unsafe-swiftshader",
            "--hide-scrollbars",
            "--force-device-scale-factor=1",
            f"--window-size={FRAME_W},{FRAME_H}",
            f"--remote-debugging-port={CDP_PORT}",
            "--mute-audio",
            "--use-fake-ui-for-media-stream",
            "--use-fake-device-for-media-stream",
            "--autoplay-policy=no-user-gesture-required",
            APP_URL,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL)
        page = None
        deadline = time.monotonic() + 30
        while page is None:
            if time.monotonic() > deadline:
                raise RuntimeError("chromium CDP never came up")
            try:
                targets = json.loads(
                    urllib.request.urlopen(f"http://127.0.0.1:{CDP_PORT}/json/list",
                                           timeout=2).read())
                page = next(t for t in targets if t.get("type") == "page")
            except Exception:
                await asyncio.sleep(0.3)
        ws = await websockets.connect(page["webSocketDebuggerUrl"], max_size=64 * 1024 * 1024)
        self.cdp = CDP(ws, on_event=self._on_event)
        await self.cdp.call("Page.enable")
        # headless=new viewport != --window-size (measured 640x337: window
        # chrome eats height). Pin the exact camera frame:
        await self.cdp.call(
            "Emulation.setDeviceMetricsOverride",
            width=FRAME_W, height=FRAME_H, deviceScaleFactor=1, mobile=False)
        t0 = time.monotonic()
        ready = False
        while time.monotonic() - t0 < BOOT_TIMEOUT:
            try:
                r = await self.cdp.call(
                    "Runtime.evaluate",
                    expression="!!(window.__max2 && window.__max2.ready "
                               "&& !document.getElementById('boot2'))")
                if r.get("result", {}).get("value"):
                    ready = True
                    break
            except Exception:
                pass
            await asyncio.sleep(0.5)
        log(f"chromium up (face ready={ready}, boot={time.monotonic()-t0:.1f}s)")
        if not ready:
            raise RuntimeError("app face never booted")
        await self.cdp.call(
            "Page.startScreencast", format="jpeg", quality=QUALITY,
            maxWidth=FRAME_W, maxHeight=FRAME_H, everyNthFrame=EVERY_NTH)

    async def stop(self):
        if self.cdp:
            try:
                await self.cdp.call("Page.stopScreencast", timeout=3)
            except Exception:
                pass
            self.cdp.reader.cancel()
            try:
                await self.cdp.ws.close()
            except Exception:
                pass
        if self.proc and self.proc.returncode is None:
            self.proc.kill()
            try:
                await asyncio.wait_for(self.proc.wait(), timeout=5)
            except Exception:
                pass
        self.cdp = None
        self.proc = None


subscribers: set = set()
latest: bytes | None = None
capture_task: asyncio.Task | None = None


def broadcast(jpeg: bytes):
    global latest
    latest = jpeg
    for s in list(subscribers):
        try:
            asyncio.get_running_loop().create_task(s.send(jpeg))
        except Exception:
            subscribers.discard(s)


async def capture_loop():
    """Restart-on-failure: (re)launch chromium with a live screencast while
    subscribers exist; frames flow through CDP events into broadcast()."""
    backoff = 1.0
    while subscribers:
        r = Renderer(broadcast)
        try:
            await r.start()
            backoff = 1.0
            while subscribers:
                await asyncio.sleep(1.0)
                if r.proc is None or r.proc.returncode is not None:
                    raise RuntimeError(f"chromium exited rc={getattr(r.proc, 'returncode', None)}")
                if time.monotonic() - r.last_frame_at > 5.0:
                    raise RuntimeError("screencast went silent (>5s no frames)")
        except asyncio.CancelledError:
            break
        except Exception as e:
            log(f"renderer broke: {e!r}; restart in {backoff:.0f}s")
            try:
                await asyncio.wait_for(asyncio.shield(_sleep(backoff)), 60)
            except (asyncio.TimeoutError, asyncio.CancelledError):
                pass
            backoff = min(RECONNECT_MAX, backoff * 2)
        finally:
            await r.stop()
    log("no subscribers: chromium stopped")


async def _sleep(s):
    await asyncio.sleep(s)


def ensure_capture_loop():
    global capture_task
    if capture_task is None or capture_task.done():
        capture_task = asyncio.create_task(capture_loop())


async def handle(ws):
    path = ws.request.path if ws.request else "/"
    if path not in ("/frames", "/", ""):
        await ws.close(code=1002, reason="use /frames")
        return
    subscribers.add(ws)
    log(f"subscriber {ws.remote_address} ({len(subscribers)} total)")
    ensure_capture_loop()
    if latest:
        try:
            await ws.send(latest)
        except Exception:
            pass
    try:
        async for _ in ws:  # control messages reserved, not needed yet
            pass
    except Exception:
        pass
    finally:
        subscribers.discard(ws)
        log(f"subscriber left ({len(subscribers)} total)")


async def main():
    serve_web()
    async with websockets.serve(handle, "0.0.0.0", PORT, max_size=2**16):
        log(f"listening on :{PORT} (/frames; app={APP_URL})")
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
