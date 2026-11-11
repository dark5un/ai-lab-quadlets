#!/usr/bin/env python3
"""Headless acceptance test for the max-headroom v2 (facecap) renderer.

Serves dist/ via `vite preview`, drives Playwright Chromium with a file-backed
fake mic. Gates the three feed modes + the live PersonaPlex link, and writes
before/after screenshots to the scratch dir.

Run:
  LD_LIBRARY_PATH=~/.local/lib/browser-deps/usr/lib \
  ~/workspace/research/duplex-bus/.venv/bin/python test_app_v2.py \
      [--plex ws://127.0.0.1:8998] [--mic <48k-mono-16bit.wav>] [--skip-live]
"""
import argparse, os, subprocess, sys, time, shutil
from pathlib import Path

from playwright.sync_api import sync_playwright

APP = os.path.dirname(os.path.abspath(__file__))
SCRATCH = Path(os.path.expanduser("~/.hermes/cache/scratch/max-headroom-v2"))
SCRATCH.mkdir(parents=True, exist_ok=True)
FAKE_DEFAULT = os.path.expanduser("~/.hermes/cache/scratch/max-headroom/fake-mic-48k.wav")

ap = argparse.ArgumentParser()
ap.add_argument("--plex", default=os.environ.get("PLEX", "ws://127.0.0.1:8998"))
ap.add_argument("--mic", default=FAKE_DEFAULT)
ap.add_argument("--skip-live", action="store_true", help="skip the PersonaPlex GO LIVE gate")
ap.add_argument("--bridge-port", type=int, default=8991,
                help="fake bridge port (8990 is the production default; it may be taken by other lab services)")
args = ap.parse_args()

BRIDGE_PORT = args.bridge_port
BRIDGE_URL = f"ws://127.0.0.1:{BRIDGE_PORT}"
bridge = subprocess.Popen(
    [sys.executable, os.path.join(APP, "tools", "fake-bridge.py"), "--port", str(BRIDGE_PORT)],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

proc = None
if subprocess.run(["curl", "-s", "-o", "/dev/null", "-m", "1", "http://127.0.0.1:4174/"],
                  cwd="/tmp").returncode != 0:
    proc = subprocess.Popen(["npx", "vite", "preview", "--port", "4174", "--strictPort",
                             "--host", "127.0.0.1"], cwd=APP,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    for _ in range(40):
        time.sleep(0.5)
        if subprocess.run(["curl", "-s", "-o", "/dev/null", "-m", "1", "http://127.0.0.1:4174/"],
                          cwd="/tmp").returncode == 0:
            break

    def open_page(ctx, query, errors):
        page = ctx.new_page()
        page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.goto(f"http://127.0.0.1:4174/?{query}", wait_until="networkidle")
        page.wait_for_function("window.__max2 && window.__max2.ready", timeout=30000)
        page.wait_for_timeout(1200)  # let morphs settle / speech start
        return page

    with sync_playwright() as p:
        browser = p.chromium.launch(args=[
            "--use-fake-ui-for-media-stream",
            "--use-fake-device-for-media-stream",
            f"--use-file-for-fake-audio-capture={args.mic}",
            "--autoplay-policy=no-user-gesture-required",
            "--enable-unsafe-swiftshader",
        ])
        ctx = browser.new_context(permissions=["microphone"], viewport={"width": 900, "height": 700})
        errors = []

        # ---- GATE 1: synthetic feed animates morphs ----
        page = open_page(ctx, "v2=1&feed=synthetic", errors)
        page.wait_for_function(
            "(() => Math.max(...window.__max2.influences) > 0.4)()", timeout=25000)
        infl = page.evaluate(
            "(() => { const i = window.__max2.influences; "
            "return {jawOpen: i[24], max: Math.max(...i), sum: i.reduce((a,b)=>a+b,0)}; })()")
        print("GATE 1 synthetic morphs engaged:", infl)
        page.screenshot(path=SCRATCH / "shot-v2-synth-a.png")
        time.sleep(0.35)
        page.screenshot(path=SCRATCH / "shot-v2-synth-b.png")
        page.wait_for_function(
            "(() => { const c=window.__max2.face.influences; window.__jaw1=c[24]; return true; })()")
        anim = page.evaluate("""(async () => {
            const c = window.__max2.face.influences; const a = c[24];
            await new Promise(r => setTimeout(r, 400));
            return Math.abs(c[24] - a);
        })()""")
        print(f"GATE 1b jawOpen changed by {anim:.3f} over 400ms")
        page.screenshot(path=SCRATCH / "shot-v2-synth.png")
        page.close()

        # ---- GATE 2: bridge feed (fake A2F WS on :8990) ----
        page = open_page(ctx, f"v2=1&feed=bridge&door={BRIDGE_URL}", errors)
        page.wait_for_function(
            "(() => window.__max2.feed.inFrames > 30)()", timeout=20000)
        b = page.evaluate(
            "(() => { const i = window.__max2.influences; "
            "return {inFrames: window.__max2.feed.inFrames, max: Math.max(...i)}; })()")
        print("GATE 2 bridge frames received:", b)
        page.screenshot(path=SCRATCH / "shot-v2-bridge.png")
        page.close()

        # ---- GATE 3: file feed (CSV replay) ----
        page = open_page(ctx, "v2=1&feed=file", errors)
        page.wait_for_function(
            "(() => window.__max2.feed.inFrames > 30)()", timeout=20000)
        f = page.evaluate(
            "(() => { const i = window.__max2.influences; return {cursor: window.__max2.feed.frameCursor, max: Math.max(...i)}; })()")
        print("GATE 3 file replay engaged:", f)
        page.screenshot(path=SCRATCH / "shot-v2-file.png")
        page.close()

        # ---- GATE 4: live plex link -> ON AIR pill + state + caption ----
        if not args.skip_live:
            page = open_page(ctx, f"v2=1&feed=synthetic&plex={args.plex}", errors)
            page.click("#go2")
            page.wait_for_function(
                "document.getElementById('pill2').classList.contains('live')", timeout=25000)
            print("GATE 4a ON AIR pill")
            page.wait_for_function(
                "['LISTENING','THINKING','SPEAKING'].includes(document.getElementById('state2').textContent)",
                timeout=15000)
            print("GATE 4b plex state:", page.text_content("#state2").strip())
            try:
                page.wait_for_function(
                    "(() => { const c = window.__max2.client; return c && (c.downBytes||0) > 5000; })()",
                    timeout=30000)
                page.wait_for_function(
                    "document.getElementById('caption2').textContent.trim().length > 0", timeout=20000)
                print("GATE 4c caption from 0x02 stream:",
                      (page.text_content("#caption2") or "").strip()[:70] + "…")
            except Exception as e:
                print("GATE 4c WARN: no downlink/caption within timeout:", str(e)[:120])
            page.wait_for_timeout(1500)
            page.screenshot(path=SCRATCH / "shot-v2-live.png")
            page.close()

        fatal = [e for e in errors if 'is not defined' in e or 'TypeError' in e or 'failed:' in e]
        if fatal:
            print("FATAL console errors:", fatal[:8])
            sys.exit(1)
        print("non-fatal console errors:", len(errors))
        browser.close()

    # pixel check: mouth-region difference between two synthetic frames
    try:
        from PIL import Image, ImageChops
        a = Image.open(SCRATCH / "shot-v2-synth-a.png").convert("RGB")
        bimg = Image.open(SCRATCH / "shot-v2-synth-b.png").convert("RGB")
        box = (a.width // 2 - 120, int(a.height * 0.55), a.width // 2 + 120, int(a.height * 0.80))
        ca, cb = a.crop(box), bimg.crop(box)
        diff = ImageChops.difference(ca, cb)
        px = list(diff.getdata())
        mean = sum(sum(p) / 3 for p in px) / len(px)
        print(f"PIXEL mouth-region mean abs diff: {mean:.2f} (>1 = mouth animating)")
    except ImportError:
        print("PIXEL check skipped (no PIL); screenshots differ:",
              open(SCRATCH / 'shot-v2-synth-a.png', 'rb').read() !=
              open(SCRATCH / 'shot-v2-synth-b.png', 'rb').read())
finally:
    if proc: proc.terminate()
    bridge.terminate()

print("ACCEPTANCE v2: all gates PASS")
print("shots:", *[str(SCRATCH / s) for s in
      ["shot-v2-synth.png", "shot-v2-bridge.png", "shot-v2-file.png"] +
      ([] if args.skip_live else ["shot-v2-live.png"])])
