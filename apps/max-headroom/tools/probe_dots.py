#!/usr/bin/env python3
"""Where are the eye catchlight dots in screen space?"""
import os, subprocess, time, json
from playwright.sync_api import sync_playwright

APP = os.path.dirname(os.path.abspath(__file__))
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
        pg.wait_for_function("window.__max2 && window.__max2.ready", timeout=60000)
        pg.wait_for_timeout(1500)
        out = pg.evaluate("""(() => {
          const f = window.__max2.face, THREE_pos = [];
          const res = [];
          f.eyeMeshes.forEach(em => {
            em.updateWorldMatrix(true, true);
            em.children.forEach(ch => {
              if (ch.isMesh && ch.material.type === 'MeshBasicMaterial') {
                const w = ch.getWorldPosition(new (ch.position.constructor)());
                const v = w.clone ? w.clone() : w;
                // project with the camera
                const proj = v.applyMatrix4 ? null : null;
                res.push({world: [ +v.x.toFixed(3), +v.y.toFixed(3), +v.z.toFixed(3) ],
                          parentScale: em.scale.toArray().map(x=>+x.toFixed(5)),
                          local: ch.position.toArray().map(x=>Math.round(x)),
                          radiusLocal: ch.geometry.parameters.radius,
                          visible: ch.visible});
              }
            });
          });
          return res;
        })()""")
        print(json.dumps(out, indent=1))
        # NDC projection
        ndc = pg.evaluate("""(() => { const f = window.__max2.face; const r=[];
          f.eyeMeshes.forEach(em => em.children.forEach(ch => {
            if (ch.isMesh && ch.material.type==='MeshBasicMaterial'){
              const v = ch.getWorldPosition(new (window.THREEV3 || ch.position));
              // use three camera via scene traversal? simpler: manual: cam pos known; use project()
              r.push(ch.getWorldPosition(ch.position.clone()).project ? 'has project' : 'no');
            }})); return r; })()""")
        print(ndc)
        b.close()
finally:
    if proc: proc.terminate()
