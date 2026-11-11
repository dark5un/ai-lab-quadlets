#!/usr/bin/env python3
"""Ad-hoc probe: dump the v2 scene graph + A/B mouth renders (inner light off,
teeth toggled) to identify stray bright beads in the mouth."""
import os, subprocess, sys, time
from playwright.sync_api import sync_playwright

proc = None
if subprocess.run(["curl","-s","-o","/dev/null","-m","1","http://127.0.0.1:4174/"],cwd="/tmp").returncode != 0:
    proc = subprocess.Popen(["npx","vite","preview","--port","4174","--strictPort","--host","127.0.0.1"],
        cwd=os.path.dirname(os.path.abspath(__file__)), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for _ in range(30):
    time.sleep(0.4)
    if subprocess.run(["curl","-s","-o","/dev/null","-m","1","http://127.0.0.1:4174/"],cwd="/tmp").returncode==0: break

OUT = os.path.expanduser("~/.hermes/cache/scratch/max-headroom-v2")
with sync_playwright() as p:
    b = p.chromium.launch(args=["--autoplay-policy=no-user-gesture-required","--enable-unsafe-swiftshader"])
    pg = b.new_context(viewport={"width":900,"height":700}).new_page()
    pg.on("console", lambda m: print("CONSOLE", m.type, m.text[:200]))
    pg.on("pageerror", lambda e: print("PAGEERROR", str(e)[:300]))
    pg.goto("http://127.0.0.1:4174/?v2=1&feed=file", wait_until="networkidle")
    print("READY?", pg.evaluate("!!window.__max2 && window.__max2 && window.__max2.ready"))
    pg.wait_for_function("window.__max2 && window.__max2.ready", timeout=40000)
    pg.wait_for_timeout(1500)
    dump = pg.evaluate("""(() => {
      const rows = [];
      window.__max2.face.scene.traverse(o => {
        if (o.isMesh) rows.push({name:o.name||'(anon)', visible:o.visible,
          mat:o.material.type, emissive:(o.material.emissive?o.material.emissive.getHexString():'-'),
          parent:o.parent.name||'(anon)'});
      });
      return rows;
    })()""")
    for r in dump: print(r)
    pg.screenshot(path=f"{OUT}/probe-default.png")
    # freeze jawOpen to a big value for comparable frames
    pg.evaluate("""(() => { const f=window.__max2.face;
      for(let i=0;i<f.influences.length;i++) f.influences[i]=0; f.influences[24]=0.8; })()""")
    pg.wait_for_timeout(60)
    pg.screenshot(path=f"{OUT}/probe-jaw.png")
    # kill inner point light
    pg.evaluate("""(() => { const s=window.__max2.face.scene;
      s.traverse(o=>{ if(o.isPointLight) o.intensity=0; }); })()""")
    pg.wait_for_timeout(60)
    pg.screenshot(path=f"{OUT}/probe-nolight.png")
    b.close()
if proc: proc.terminate()
print("done")
