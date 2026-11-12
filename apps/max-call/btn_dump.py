import asyncio, os
from playwright.async_api import async_playwright
INJ = open('src/maxcall/inject.js').read()
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36")
async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch(headless=True, channel='chromium', args=[
            '--use-gl=angle','--use-angle=gl-egl','--autoplay-policy=no-user-gesture-required',
            '--disable-blink-features=AutomationControlled'])
        ctx = await b.new_context(user_agent=UA, locale='en-GB')
        await ctx.add_init_script('window.__maxRole="call";window.__maxNoPc=1;')
        await ctx.add_init_script(INJ)
        pg = await ctx.new_page()
        await pg.goto('https://meet.google.com/agn-ezui-qwe', wait_until='domcontentloaded')
        for t in range(10):
            await asyncio.sleep(2)
            info = await pg.evaluate("""() => [...document.querySelectorAll('button,[role=button]')]
                .map(x => ({txt: (x.innerText||'').trim().slice(0,20), aria: (x.getAttribute('aria-label')||'').slice(0,30),
                            dis: x.disabled, vis: !!(x.offsetWidth||x.offsetHeight)}))
                .filter(x => x.txt||x.aria)""")
            joinlike = [x for x in info if 'join' in (x['txt']+x['aria']).lower()]
            print('t', t*2, 'join-ish:', joinlike, flush=True)
            if joinlike and any(x['vis'] and not x['dis'] for x in joinlike):
                try:
                    await pg.get_by_role('button', name='Join now').first.click(timeout=3000)
                    print('CLICKED via role; url now:', pg.url, flush=True)
                except Exception as e:
                    print('click fail:', type(e).__name__, str(e)[:150], flush=True)
                    await pg.evaluate("""() => { const b=[...document.querySelectorAll('button,[role=button]')]
                        .find(x=>/join now/i.test((x.innerText||'')+(x.getAttribute('aria-label')||''))); if(b) b.click(); }""")
                    print('js-clicked; url:', pg.url, flush=True)
                await asyncio.sleep(6)
                inc = await pg.evaluate("() => !!document.querySelector('[data-id=\"leave-call-button\"]')")
                print('IN-CALL:', inc, '| url:', pg.url, flush=True)
                await pg.screenshot(path='artifacts/btndump_after.png')
                break
        await b.close()
asyncio.run(main())
