#!/usr/bin/env python3
"""A/B probe of mouth beads: baseline, map-off, fresnel-off."""
import os, subprocess, time
from playwright.sync_api import sync_playwright

APP = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.expanduser("~/.hermes/cache/scratch/max-headroom-v2")
proc = subprocess.Popen(["npx","vite","preview","--port","4176","--strictPort","--host","127.0.0.1"],
    cwd=APP, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for _ in range(40):
    time.sleep(0.5)
    if subprocess.run(["curl","-s","-o","/dev/null","-m","1","http://127.0.0.1:4176/"],cwd="/tmp").returncode==0: break
try:
    with sync_playwright() as p:
        b = p.chromium.launch(args=["--autoplay-policy=no-user-gesture-required","--enable-unsafe-swiftshader"])
        pg = b.new_context(viewport={"width":900,"height":700}).new_page()
        pg.on("console", lambda m: print("CONSOLE", m.type, m.text[:150]))
        pg.on("pageerror", lambda e: print("PAGEERROR", str(e)[:200]))
        pg.goto("http://127.0.0.1:4176/?v2=1&feed=file", wait_until="networkidle")
        pg.wait_for_function("window.__max2 && window.__max2.ready", timeout=40000)
        pg.wait_for_timeout(2500)
        # freeze influences for identical frames: stop smoothing by pinning target
        pg.evaluate("""(() => { const f=window.__max2.feed; f.tick = ()=>{}; })()""")
        pg.wait_for_timeout(300)
        pg.screenshot(path=f"{OUT}/ab-baseline.png")
        pg.evaluate("window.__max2.face.headMesh.material.map = null; window.__max2.face.headMesh.material.needsUpdate = true;")
        pg.wait_for_timeout(300)
        pg.screenshot(path=f"{OUT}/ab-nomap.png")
        b.close()
finally:
    proc.terminate()
print("done")
