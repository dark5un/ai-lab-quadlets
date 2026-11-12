"""max-call callpage — put the REAL avatar into a WebRTC call.

Two tabs, one browser (no kernel devices, no page-CSP fights, no protocol
reimplementation — the app tab keeps speaking PersonaPlex natively):

  APP tab  : our v2 app (?v2=1&feed=bridge), WebSocket-siphoned downlink
             (Max's voice), mic replaced by the call's far-end audio.
  CALL tab : Meet (or echo.html for self-test) with getUserMedia patched to
             a mirrored canvas of the APP tab + Max's decoded audio.

Driver loops: frames (CDP screencast -> drawImage), downlink ogg pages ->
ffmpeg -> 24k s16 -> call audio buffer; call remote 48k s16 -> decimate 24k
-> app mic buffer.

Usage:
  python callpage.py --meet-url https://meet.google.com/xxx-xxxx-xxx [--hold 300]
  python callpage.py --self-test        # loopback echo room, asserts plumbing
"""
from __future__ import annotations
import argparse, asyncio, base64, json, os, re, struct, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
INJECT = (HERE / 'inject.js').read_text()
ECHO = HERE / 'echo.html'
FFMPEG = os.path.expanduser('~/.hermes/tools/ffmpeg-9.0.1-linux-x64/bin/ffmpeg')
APP_URL = os.environ.get('APP', 'http://127.0.0.1:4174/?v2=1&feed=bridge')
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko)"
      " Chrome/141.0.0.0 Safari/537.36")


async def run(target: str, hold: float, self_test: bool) -> int:
    from playwright.async_api import async_playwright

    ff = await asyncio.create_subprocess_exec(
        FFMPEG, '-loglevel', 'error', '-f', 'ogg', '-i', 'pipe:0',
        '-ar', '24000', '-ac', '1', '-f', 's16le', 'pipe:1',
        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE)
    pcm_out = asyncio.Queue()
    pcm_bridge = asyncio.Queue()

    async def read_ff():
        while True:
            chunk = await ff.stdout.read(3840)  # 80 ms of 24k s16
            if not chunk:
                break
            await pcm_out.put(chunk)
            await pcm_bridge.put(chunk)
    rff = asyncio.create_task(read_ff())
    # bridge feed client: Max's own voice -> A2F -> blendshapes for app tab
    BRIDGE = os.environ.get('BRIDGE', 'ws://127.0.0.1:8990')
    bridge_box = {'ws': None}

    async def bridge_feed_pump():
        while True:
            try:
                async with websockets.connect(BRIDGE + '/feed') as ws:
                    await ws.send(json.dumps({'rate': 24000}))
                    bridge_box['ws'] = ws
                    while True:
                        chunk = await pcm_bridge.get()
                        await ws.send(chunk)
            except Exception:
                bridge_box['ws'] = None
                await asyncio.sleep(1.0)
    latest_frame = None
    rbp_task = asyncio.create_task(bridge_feed_pump())

    async with async_playwright() as p:
        browser = await p.chromium.launch(
            headless=True, channel='chromium', args=[
                '--use-gl=angle', '--use-angle=gl-egl',
                '--autoplay-policy=no-user-gesture-required',
                '--disable-blink-features=AutomationControlled'])

        appctx = await browser.new_context(user_agent=UA, locale='en-GB')
        await appctx.add_init_script('window.__maxRole="app";')
        await appctx.add_init_script(INJECT)
        app = await appctx.new_page()
        await app.goto(APP_URL)
        # go live on the app (its own GO LIVE button)
        try:
            await app.wait_for_selector('button', timeout=15000)
            await app.get_by_role('button', name=re.compile('go live', re.I)).first.click(timeout=5000)
            print('[driver] app GO LIVE clicked', flush=True)
        except Exception as e:
            print('[driver] GO LIVE click failed:', type(e).__name__, str(e)[:140], flush=True)
        cdp = await appctx.new_cdp_session(app)
        frame_box = []

        def frame_cb(ev):
            frame_box.append(ev['data'])
            asyncio.ensure_future(cdp.send('Page.screencastFrameAck',
                                           {'sessionId': ev['sessionId']}))
        cdp.on('Page.screencastFrame', frame_cb)
        await cdp.send('Page.startScreencast',
                       {'format': 'jpeg', 'quality': 65, 'everyNthFrame': 1,
                        'maxWidth': 640, 'maxHeight': 480})

        callctx = await browser.new_context(user_agent=UA, locale='en-GB')
        await callctx.add_init_script('window.__maxRole="call";')
        await callctx.add_init_script(INJECT)
        call = await callctx.new_page()
        await call.goto(target, wait_until='domcontentloaded', timeout=45000)

        joined = self_test  # echo page needs no join click
        t0 = time.time()
        ticks = 0
        while time.time() - t0 < hold:
            ticks += 1
            # 1) frame mirror
            if frame_box:
                b64 = frame_box.pop()
                try:
                    await call.evaluate(
                        '''(b64)=>{const c=window.__maxCanvas;const img=new Image();
                        img.onload=()=>c.getContext('2d').drawImage(img,0,0,c.width,c.height);
                        img.src='data:image/jpeg;base64,'+b64;}''', b64)
                except Exception:
                    pass
            # 2) app downlink ogg -> ffmpeg -> call audio
            try:
                pages = await app.evaluate('window.__maxPopDownlink()')
                for pg in pages:
                    ff.stdin.write(base64.b64decode(pg))
                await ff.stdin.drain()
            except Exception:
                pass
            while not pcm_out.empty():
                await call.evaluate('(b64)=>window.__maxPushAudio(b64)',
                                    base64.b64encode(await pcm_out.get()).decode())
            # 3) call remote audio -> app mic
            try:
                rem = await call.evaluate('window.__maxPopRemoteAudio()')
                for c in rem:
                    n = len(c)
                    i16 = struct.unpack(f'<{n}h', base64.b64decode(c))
                    mic = i16[::2]  # 48k -> 24k decimation (v1)
                    await app.evaluate('(b64)=>window.__maxPushMic(b64)',
                                       base64.b64encode(
                                           struct.pack(f'<{len(mic)}h', *mic)).decode())
            except Exception:
                pass
            # 4) meet join flow
            if not joined:
                try:
                    btn = call.get_by_test_id("join-button")
                    if await btn.count() == 0:
                        btn = call.get_by_role("button",
                                               name=re.compile(r"join now", re.I))
                    await btn.first.click(timeout=2500)
                    joined = True
                    print('[driver] clicked JOIN NOW', flush=True)
                except Exception:
                    if ticks % 40 == 1:
                        t = await call.evaluate("() => document.body.innerText.slice(0,150)")
                        print('[driver] prejoin text:', ' '.join(t.split())[:140], flush=True)
            if ticks % 200 == 1:
                try:
                    stt = await app.evaluate("() => String(window.__max2 && window.__max2.state)")
                    if stt == 'STANDBY':
                        await app.get_by_role('button', name=re.compile('go live', re.I)).first.click(timeout=2000)
                        print('[driver] re-click GO LIVE (was STANDBY)', flush=True)
                except Exception:
                    pass
                try:
                    st = await app.evaluate("() => window.__max2 ? {state: String(window.__max2.state), ready: window.__max2.ready, frames: window.__max2.feed.inFrames, ws: !!(window.__max2.client && window.__max2.client.ws)} : null")
                    print(f'[driver] app state t={time.time()-t0:.0f}s:', st, flush=True)
                    await call.screenshot(path=str(HERE / 'artifacts/call_tab.png'))
                except Exception as e:
                    print('[driver] probe fail:', repr(e), flush=True)
            await asyncio.sleep(0.05)

        if self_test:
            st = await call.evaluate('window.__echo')
            print('echo state:', json.dumps(st), flush=True)
            px = await call.evaluate('''() => {
                const c = window.__maxCanvas;
                const d = c.getContext('2d').getImageData(0,0,c.width,c.height).data;
                let lit = 0; for (let i=0;i<d.length;i+=4)
                  if (d[i]+d[i+1]+d[i+2] > 90) lit++;
                return lit; }''')
            print('lit canvas px:', px, flush=True)
            ok = (st.get('remoteGot', 0) > 0 and not st.get('err')
                  and 'video' in ' '.join(st.get('tracks', [])) and px > 100)
            print('SELF-TEST:', 'PASS' if ok else 'FAIL', flush=True)
            rc = 0 if ok else 1
        else:
            rc = 0

        await browser.close()
    try:
        ff.stdin.close()
    except Exception:
        pass
    try:
        ff.kill()
    except Exception:
        pass
    rff.cancel()
    return rc


def _frame_cb(*a):
    pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--meet-url')
    ap.add_argument('--self-test', action='store_true')
    ap.add_argument('--hold', type=float, default=60)
    a = ap.parse_args()
    if a.self_test:
        target = f'file://{ECHO}'
    else:
        assert a.meet_url
        target = a.meet_url
    sys.exit(asyncio.run(run(target, a.hold, a.self_test)))


if __name__ == '__main__':
    main()
