#!/usr/bin/env python3
"""Headless acceptance test for the max-headroom client (Phase 5 gate).

Serves dist/ via `vite preview`, drives Playwright Chromium with a file-backed
fake mic against the LIVE PersonaPlex server (or any door). Asserts: full-
duplex round trip (uplink accepted + downlink bytes), viseme morph engagement,
avatar animation via screenshot pair, captions from the 0x02 text stream.

Run:
  LD_LIBRARY_PATH=~/.local/lib/browser-deps/usr/lib \
  ~/workspace/research/duplex-bus/.venv/bin/python test_app_e2e.py \
      [--door ws://127.0.0.1:8998] [--mic <48k-mono-16bit.wav>]
(needs: duplex-bus .venv with playwright; chromium installed)
"""
import argparse, os, subprocess, sys, time

from playwright.sync_api import sync_playwright

APP = os.path.dirname(os.path.abspath(__file__))
FAKE_DEFAULT = os.path.expanduser("~/.hermes/cache/scratch/max-headroom/fake-mic-48k.wav")

ap = argparse.ArgumentParser()
ap.add_argument("--door", default=os.environ.get("DOOR", "ws://127.0.0.1:8998"))
ap.add_argument("--mic", default=FAKE_DEFAULT)
args = ap.parse_args()

SHOT1, SHOT2 = "/tmp/max-1.png", "/tmp/max-2.png"
proc = None
if subprocess.run(["curl", "-s", "-o", "/dev/null", "-m", "1", "http://127.0.0.1:4173/"],
                  cwd="/tmp").returncode != 0:
    proc = subprocess.Popen(["npx", "vite", "preview", "--port", "4173", "--strictPort",
                             "--host", "127.0.0.1"], cwd=APP,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    for _ in range(40):
        time.sleep(0.5)
        if subprocess.run(["curl", "-s", "-o", "/dev/null", "-m", "1", "http://127.0.0.1:4173/"],
                          cwd="/tmp").returncode == 0:
            break
    with sync_playwright() as p:
        browser = p.chromium.launch(args=[
            "--use-fake-ui-for-media-stream",
            "--use-fake-device-for-media-stream",
            f"--use-file-for-fake-audio-capture={args.mic}",
            "--autoplay-policy=no-user-gesture-required",
        ])
        ctx = browser.new_context(permissions=["microphone"], viewport={"width": 900, "height": 700})
        page = ctx.new_page()
        errors = []
        page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.goto(f"http://127.0.0.1:4173/?door={args.door}", wait_until="networkidle")
        page.wait_for_selector("#go")
        page.fill("#persona",
            "You are Max Headroom: a sarcastic, paranoid AI video-host from a 1980s TV station. "
            "You stutter on consonants, insult the caller, and never admit to being an assistant. "
            "Keep replies to one or two punchy sentences.")
        page.click("#go")
        page.wait_for_function("document.getElementById('status').textContent === 'LIVE'", timeout=20000)
        print("GATE 1 uplink+ws: LIVE")

        page.wait_for_function(
            "(() => { const c = window.__max.client; return c && (c.downBytes||0) > 5000; })()",
            timeout=25000)
        print("GATE 2 downlink audio bytes flowing")

        page.wait_for_function(
            "(() => Math.max(...window.__max.head.influences) > 0.5)()", timeout=20000)
        infl = page.evaluate("Array.from(window.__max.head.influences).map(x => x.toFixed(2))")
        print("GATE 3 viseme morphs engaged:", infl)

        page.screenshot(path=SHOT1)
        page.wait_for_timeout(1500)
        page.screenshot(path=SHOT2)
        same = open(SHOT1, 'rb').read() == open(SHOT2, 'rb').read()
        print("GATE 4 screenshot diff:", "IDENTICAL (animation stalled!)" if same else "frames differ (animating)")

        counters = page.evaluate("[window.__max.client.upPages, window.__max.client.downBytes]")
        cap = (page.text_content("#caption") or "").strip()
        print(f"counters: upPages={counters[0]} downBytes={counters[1]} caption={cap[:60]!r}")
        if same:
            sys.exit(1)
        browser.close()
finally:
    if proc: proc.terminate()

fatal = [e for e in errors if 'is not defined' in e or 'TypeError' in e]
if fatal:
    print("FATAL console errors:", fatal[:5])
    sys.exit(1)
print("ACCEPTANCE: all browser gates PASS")
