"""Re-capture screenshots 01-05 with longer waits for streaming content."""
import asyncio
import os
from playwright.async_api import async_playwright

BASE = f"http://127.0.0.1:8080/home.html?passcode={os.environ.get('ALFRED_PASSCODE', 'YOUR_PASSCODE')}"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)))

async def hide_health_warning(page):
    await page.evaluate("""() => {
        const divs = [...document.querySelectorAll('div')];
        const hw = divs.find(d => d.innerHTML && d.innerHTML.includes('System Health') && d.innerHTML.includes('Full Disk') && d.offsetHeight < 200);
        if (hw) hw.style.display = 'none';
    }""")

async def wait_for_content(page, timeout_s=90):
    """Wait until skeleton loaders are gone and real text is visible."""
    for i in range(timeout_s):
        has_skeletons = await page.evaluate("""() => {
            return document.querySelectorAll('.skeleton, .skeleton-line, [class*="skeleton"]').length > 0
                || document.body.innerText.includes('loading...')
                || document.querySelectorAll('.loading-dots, .typing-indicator').length > 0;
        }""")
        if not has_skeletons and i > 10:
            break
        await page.wait_for_timeout(1000)
    # Extra buffer for streaming to finish
    await page.wait_for_timeout(3000)

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch()
        ctx = await browser.new_context(viewport={"width": 375, "height": 812})
        page = await ctx.new_page()
        await page.goto(BASE)

        print("⏳ Waiting for pulse observations to stream in...")
        await wait_for_content(page, 120)
        await hide_health_warning(page)

        # 1. Home with loaded observations
        await page.evaluate("window.scrollTo(0, 0)")
        await page.screenshot(path=f"{OUT}/01_home_evening_wrapup.png")
        print("✓ 01 Home")

        # 2. Expand observations
        await page.evaluate("() => { const s = document.querySelector('summary'); if (s) s.click(); }")
        await page.wait_for_timeout(1000)
        await page.screenshot(path=f"{OUT}/02_observations_expanded.png")
        print("✓ 02 Observations expanded")

        # 3. Scroll down
        await page.evaluate("window.scrollBy(0, 500)")
        await page.wait_for_timeout(500)
        await page.screenshot(path=f"{OUT}/03_focus_follow_through.png")
        print("✓ 03 Focus/follow through")

        # 4. Calendar - wait for full response
        await page.evaluate("""() => {
            const btn = [...document.querySelectorAll('button')].find(b => b.textContent.trim() === 'Calendar');
            if (btn) btn.click();
        }""")
        print("⏳ Waiting for calendar...")
        # Wait for calendar card to appear
        for i in range(60):
            has_card = await page.evaluate("""() => {
                return document.body.innerText.includes('events') &&
                       document.body.innerText.includes('AM') || document.body.innerText.includes('PM');
            }""")
            if has_card and i > 5:
                break
            await page.wait_for_timeout(1000)
        # Wait for coaching response after the card
        await page.wait_for_timeout(15000)
        await page.set_viewport_size({"width": 375, "height": 1400})
        await page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
        await page.wait_for_timeout(1000)
        await page.screenshot(path=f"{OUT}/04_calendar_tool_card.png")
        print("✓ 04 Calendar")

        # 5. Overdue - wait for full response
        await page.evaluate("""() => {
            const btn = [...document.querySelectorAll('button')].find(b => b.textContent.trim() === 'Overdue');
            if (btn) btn.click();
        }""")
        print("⏳ Waiting for overdue...")
        for i in range(60):
            has_card = await page.evaluate("""() => {
                return document.body.innerText.includes('Commitments') &&
                       document.body.innerText.includes('overdue');
            }""")
            if has_card and i > 5:
                break
            await page.wait_for_timeout(1000)
        await page.wait_for_timeout(15000)
        await page.set_viewport_size({"width": 375, "height": 1800})
        await page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
        await page.wait_for_timeout(1000)
        await page.screenshot(path=f"{OUT}/05_overdue_commitments.png")
        print("✓ 05 Overdue")

        await ctx.close()
        await browser.close()
        print(f"\n✅ Screenshots 01-05 re-captured")

asyncio.run(main())
