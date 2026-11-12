import re, sys, time
from playwright.sync_api import sync_playwright

URL = "https://meet.google.com/agn-ezui-qwe"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36")

with sync_playwright() as p:
    b = p.chromium.launch(
        headless=True,
        channel="chromium",
        args=[
              "--use-gl=angle", "--use-angle=gl-egl", "--enable-gpu",
              "--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream",
              "--autoplay-policy=no-user-gesture-required",
              "--disable-blink-features=AutomationControlled"])
    ctx = b.new_context(user_agent=UA, locale="en-GB",
                        viewport={"width": 1280, "height": 800})
    page = ctx.new_page()
    await_ = page.add_init_script(
        "Object.defineProperty(navigator,'webdriver',{get:()=>undefined});")
    gl = page.evaluate("""() => { const c=document.createElement('canvas');
        const g=c.getContext('webgl'); const d=g.getExtension('WEBGL_debug_renderer_info');
        return d ? g.getParameter(d.UNMASKED_RENDERER_WEBGL) : 'none'; }""")
    print('webgl renderer:', gl, flush=True)
    page.goto(URL, wait_until="domcontentloaded", timeout=30000)
    for _ in range(15):
        time.sleep(2)
        txt = page.evaluate("() => document.body.innerText")
        btns = page.evaluate("""() => [...document.querySelectorAll('button,[role=button]')]
            .map(x => (x.getAttribute('data-id')||'') + '|' + x.innerText.trim()).filter(x=>x.length>1)""")
        print('url:', page.url, flush=True)
        print('buttons:', btns[:12], flush=True)
        print('has-join-now:', bool(re.search(r'join now', txt, re.I)), '| text head:', ' '.join(txt.split())[:180], flush=True)
        if re.search(r'join now|allow camera|meeting code', txt, re.I):
            page.screenshot(path='artifacts/ua_probe_join.png')
            break
    ctx.close(); b.close()
