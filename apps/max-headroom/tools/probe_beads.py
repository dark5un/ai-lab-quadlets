#!/usr/bin/env python3
"""Quantitative A/B of mouth-rim beads + eye catchlights via in-page readPixels."""
import os, subprocess, sys, time
from playwright.sync_api import sync_playwright

APP = os.path.dirname(os.path.abspath(__file__))
MOUTH = (0.40, 0.58, 0.60, 0.74)
EYES = (0.38, 0.38, 0.62, 0.50)

proc = None
if subprocess.run(["curl","-s","-m","1","http://127.0.0.1:4177/"],cwd="/tmp",capture_output=True).returncode != 0:
    proc = subprocess.Popen(["npx","vite","preview","--port","4177","--strictPort","--host","127.0.0.1"],
        cwd=APP, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(4)
try:
    with sync_playwright() as p:
        b = p.chromium.launch(args=["--autoplay-policy=no-user-gesture-required","--enable-unsafe-swiftshader"])
        pg = b.new_context(viewport={"width":900,"height":700}).new_page()
        pg.goto("http://127.0.0.1:4177/?v2=1&feed=file", wait_until="networkidle")
        pg.on("console", lambda m: print("CONSOLE-ERR", m.text[:150]) if m.type == "error" else None)
        pg.on("pageerror", lambda e: print("PAGEERROR", str(e)[:200]))
        pg.wait_for_function("window.__max2 && window.__max2.ready", timeout=60000)
        pg.wait_for_timeout(2000)
        # freeze animation: pin jawOpen high, stop feed updates
        pg.evaluate("""(() => {
          const f = window.__max2.face, fd = window.__max2.feed;
          fd.tick = () => {}; fd.targets.fill(0); fd.targets[24] = 0.85;
        })()""")
        pg.wait_for_timeout(500)
        def probe(tag):
            m = pg.evaluate("window.__max2.probeRegion(%s)" % ",".join(map(str, MOUTH)))
            e = pg.evaluate("window.__max2.probeRegion(%s)" % ",".join(map(str, EYES)))
            print(f"{tag:24s} mouth={m} eyes={e}")
        probe("all-on")
        pg.evaluate("window.__max2.face.rig.rotation.y = 0.45; window.__max2.face.rig.updateMatrixWorld(true)")
        pg.wait_for_timeout(150)
        probe("head-turned-45deg")
        pg.evaluate("window.__max2.face.rig.rotation.y = 0")
        pg.wait_for_timeout(100)
        pg.evaluate("window.__max2.face.innerMesh.visible = false")
        pg.wait_for_timeout(150)
        probe("innerMesh-off")
        pg.evaluate("window.__max2.face.innerMesh.visible = true; "
                    "window.__max2.face.headMesh.material.map = null;"
                    "window.__max2.face.headMesh.material.needsUpdate = true")
        pg.wait_for_timeout(150)
        probe("map-off")
        pg.screenshot(path=os.path.expanduser("~/.hermes/cache/scratch/max-headroom-v2/probe-final-mouth.png"))
        b.close()
finally:
    if proc: proc.terminate()
