import re, sys, time
from playwright.sync_api import sync_playwright

URL = "https://meet.google.com/tww-faqz-gpf"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36")

with sync_playwright() as p:
    b = p.chromium.launch(
        headless=True,
        args=["--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream",
              "--autoplay-policy=no-user-gesture-required"])
    ctx = b.new_context(user_agent=UA, locale="en-GB",
                        viewport={"width": 1280, "height": 800})
    page = ctx.new_page()
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
