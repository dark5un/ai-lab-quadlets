"""nodriver stealth join test: does Google's guest gate accept a
non-Runtime.enable CDP client with full chromium?"""
import asyncio, os, sys

CHROME = '/home/px/.hermes/cache/scratch/pw-browsers/chromium-1254/chrome-linux64/chrome'
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko)"
      " Chrome/141.0.0.0 Safari/537.36")
URL = "https://meet.google.com/agn-ezui-qwe"

import nodriver


async def main():
    browser = await nodriver.start(
        browser_executable_path=CHROME,
        headless=True,
        browser_args=[
            '--headless=new', '--no-sandbox',
            '--use-gl=angle', '--use-angle=gl-egl',
            '--disable-blink-features=AutomationControlled',
            '--autoplay-policy=no-user-gesture-required',
            f'--user-agent={UA}',
            '--lang=en-GB',
        ],
    )
    try:
        tab = await browser.get(URL)
        await asyncio.sleep(14)
        txt = await tab.evaluate("document.body.innerText.slice(0,300)", await_promise=False)
        print("TEXT:", " ".join(str(txt).split())[:280], flush=True)
        # allow modal
        for sel in ('[data-id="all-present"]', 'button[aria-label*="Allow microphone"]'):
            el = await tab.query_selector(sel)
            if el:
                await el.click()
                print("clicked allow via", sel, flush=True)
                break
        await asyncio.sleep(4)
        # name field
        nm = await tab.query_selector('input[aria-label*="name" i]')
        if nm:
            await nm.send_keys("MAX HEADROOM")
        # join
        joined = False
        for _ in range(6):
            el = await tab.query_selector('[data-id="join"], button[aria-label*="Join now" i], button[aria-label*="Join"]')
            if el:
                await el.click()
                joined = True
                print("join clicked", flush=True)
                break
            await asyncio.sleep(2)
        if not joined:
            state = await tab.evaluate(
                "JSON.stringify([...document.querySelectorAll('button')]"
                ".map(b => (b.innerText||b.getAttribute('aria-label')||'').trim()).filter(Boolean).slice(0,15))",
                await_promise=False)
            print("buttons:", state, flush=True)
        await asyncio.sleep(8)
        inc = await tab.evaluate(
            "!!document.querySelector('[data-id=\"leave-call-button\"]') || "
            "!!document.querySelector('button[aria-label*=\"Leave\"]')", await_promise=False)
        url_now = await tab.evaluate("location.href", await_promise=False)
        print("IN-CALL:", inc, "| url:", url_now, flush=True)
        shot = await tab.save_screenshot('artifacts/nd_join.png', as_base64=False)
    finally:
        await browser.stop()

if __name__ == '__main__':
    asyncio.run(main())
