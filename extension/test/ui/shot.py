import asyncio, sys, subprocess, time, os
from playwright.async_api import async_playwright
root = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
async def main():
    srv = subprocess.Popen([sys.executable, '-m', 'http.server', '8765', '-d', root], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.8)
    try:
        async with async_playwright() as p:
            b = await p.chromium.launch()
            pg = await b.new_page(viewport={'width': 1180, 'height': 1300}, color_scheme='light')
            errs = []
            pg.on('pageerror', lambda e: errs.append(str(e)))
            pg.on('console', lambda m: errs.append(m.text) if m.type == 'error' else None)
            await pg.goto('http://localhost:8765/test/ui/harness.html')
            await pg.wait_for_function('window.__ready === true', timeout=15000)
            await pg.wait_for_timeout(300)
            await pg.click('#btn-scan')
            await pg.wait_for_selector('.item')
            await pg.wait_for_timeout(500)
            await pg.screenshot(path='/tmp/ui2-scan.png', full_page=True)
            await pg.click('.t-multiConflict .choices button:nth-child(2)')
            await pg.wait_for_timeout(500)
            await pg.click('#btn-settings')
            await pg.wait_for_timeout(500)
            await pg.screenshot(path='/tmp/ui2-settings.png')
            await pg.click('#settings-body .tools button:first-child')
            await pg.wait_for_timeout(400)
            await pg.screenshot(path='/tmp/ui2-clean.png')
            if await pg.is_visible('#dlg-confirm[open]'):
                await pg.click('#dlg-confirm menu button.ghost')
            await pg.click('#dlg-settings menu button.ghost')
            await pg.click('#btn-run')
            await pg.wait_for_timeout(300)
            if await pg.is_visible('#dlg-confirm[open]'):
                await pg.click('#confirm-ok')
            await pg.wait_for_selector('#result:not([hidden])')
            await pg.wait_for_timeout(600)
            await pg.screenshot(path='/tmp/ui2-after.png', full_page=True)
            await pg.click('#btn-history')
            await pg.wait_for_selector('#history-view:not([hidden])')
            await pg.wait_for_timeout(400)
            await pg.screenshot(path='/tmp/ui2-history.png', full_page=True)
            rows = await pg.query_selector_all('.hist-row')
            if rows:
                await rows[0].click()
                await pg.wait_for_timeout(300)
                await pg.screenshot(path='/tmp/ui2-history-detail.png', clip={'x':0,'y':0,'width':1180,'height':420})
            print('history rows:', len(rows))
            print('result:', (await pg.inner_text('#result'))[:500])
            print('errors:', errs)
            await b.close()
    finally:
        srv.terminate()
asyncio.run(main())
