"""Capture all key Alfred screenshots using Playwright."""
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

async def click_btn(page, text):
    await page.evaluate(f"""() => {{
        const btn = [...document.querySelectorAll('button')].find(b => b.textContent.trim() === '{text}');
        if (btn) btn.click();
    }}""")

async def click_tab(page, text):
    await page.evaluate(f"""() => {{
        const els = [...document.querySelectorAll('*')];
        const tab = els.find(t => t.textContent.trim() === '{text}' && t.offsetHeight > 0 && t.offsetWidth < 120);
        if (tab) tab.click();
    }}""")

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch()

        # ── Mobile screenshots ──
        ctx = await browser.new_context(viewport={"width": 375, "height": 812})
        page = await ctx.new_page()
        await page.goto(BASE)
        await page.wait_for_timeout(5000)
        await hide_health_warning(page)

        # 1. Home
        await page.screenshot(path=f"{OUT}/01_home_evening_wrapup.png")
        print("✓ 01")

        # 2. Observations expanded
        await page.evaluate("() => { const s = document.querySelector('summary'); if (s) s.click(); }")
        await page.wait_for_timeout(1000)
        await page.screenshot(path=f"{OUT}/02_observations_expanded.png")
        print("✓ 02")

        # 3. Scroll to more cards
        await page.evaluate("window.scrollBy(0, 500)")
        await page.wait_for_timeout(500)
        await page.screenshot(path=f"{OUT}/03_focus_follow_through.png")
        print("✓ 03")

        # 4. Calendar
        await click_btn(page, "Calendar")
        await page.wait_for_timeout(15000)
        await page.set_viewport_size({"width": 375, "height": 1400})
        await page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
        await page.wait_for_timeout(500)
        await page.screenshot(path=f"{OUT}/04_calendar_tool_card.png")
        print("✓ 04")

        # 5. Overdue
        await click_btn(page, "Overdue")
        await page.wait_for_timeout(15000)
        await page.set_viewport_size({"width": 375, "height": 1600})
        await page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
        await page.wait_for_timeout(500)
        await page.screenshot(path=f"{OUT}/05_overdue_commitments.png")
        print("✓ 05")

        # 6. Settings — Configurations
        await page.set_viewport_size({"width": 375, "height": 812})
        await page.evaluate("window.scrollTo(0, 0)")
        await page.evaluate("""() => {
            const btn = [...document.querySelectorAll('button')].find(b => b.textContent.includes('⚙'));
            if (btn) btn.click();
        }""")
        await page.wait_for_timeout(2000)
        await page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
        await page.screenshot(path=f"{OUT}/06_settings_configurations.png")
        print("✓ 06")

        # 7. Settings — Tenets
        await click_tab(page, "tenets")
        await page.wait_for_timeout(1000)
        await page.screenshot(path=f"{OUT}/07_settings_tenets.png")
        print("✓ 07")

        # 8. Settings — Coaching
        await click_tab(page, "coaching")
        await page.wait_for_timeout(1000)
        await page.screenshot(path=f"{OUT}/08_settings_coaching.png")
        print("✓ 08")

        # 9. Settings — Library
        await click_tab(page, "library")
        await page.wait_for_timeout(1000)
        await page.screenshot(path=f"{OUT}/09_settings_library.png")
        print("✓ 09")

        # Close settings
        await page.evaluate("""() => {
            const btn = [...document.querySelectorAll('*')].find(el => el.textContent.trim() === '×' && el.offsetHeight > 0 && el.offsetHeight < 40);
            if (btn) btn.click();
        }""")
        await page.wait_for_timeout(500)

        # 10. Pin selector
        await page.evaluate("window.scrollTo(0, 0)")
        await page.wait_for_timeout(500)
        await click_btn(page, "Change")
        await page.wait_for_timeout(3000)
        await page.screenshot(path=f"{OUT}/10_pin_selector.png")
        print("✓ 10")

        # 11. Chat — reload fresh, use JS to fill chat input
        await page.goto(BASE)
        await page.wait_for_timeout(6000)
        await hide_health_warning(page)
        await page.evaluate("""() => {
            const input = document.querySelector('#chatInput, .chat-input, [placeholder*="Talk"]');
            if (input) { input.value = 'what should I focus on tomorrow?'; input.dispatchEvent(new Event('input', {bubbles:true})); }
        }""")
        await page.wait_for_timeout(500)
        await page.evaluate("""() => {
            const btns = [...document.querySelectorAll('button')];
            const btn = btns.find(b => (b.querySelector('img, svg') || b.classList.contains('send-btn')) && b.offsetHeight < 60 && b.offsetHeight > 0);
            if (btn) btn.click();
        }""")
        await page.wait_for_timeout(20000)
        await page.set_viewport_size({"width": 375, "height": 1400})
        await page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
        await hide_health_warning(page)
        await page.screenshot(path=f"{OUT}/11_chat_conversation.png")
        print("✓ 11")

        # 12. Slash commands
        await page.set_viewport_size({"width": 375, "height": 812})
        await page.evaluate("""() => {
            const input = document.querySelector('#chatInput, .chat-input, [placeholder*="Talk"]');
            if (input) { input.value = '/'; input.dispatchEvent(new Event('input', {bubbles:true})); }
        }""")
        await page.wait_for_timeout(1500)
        await page.screenshot(path=f"{OUT}/12_slash_commands.png")
        print("✓ 12")

        await ctx.close()

        # ── Tablet ──
        ctx = await browser.new_context(viewport={"width": 768, "height": 1024})
        page = await ctx.new_page()
        await page.goto(BASE)
        await page.wait_for_timeout(5000)
        await hide_health_warning(page)
        await page.screenshot(path=f"{OUT}/13_tablet_layout.png")
        print("✓ 13")
        await ctx.close()

        # ── Desktop ──
        ctx = await browser.new_context(viewport={"width": 1280, "height": 800})
        page = await ctx.new_page()
        await page.goto(BASE)
        await page.wait_for_timeout(5000)
        await hide_health_warning(page)
        await page.screenshot(path=f"{OUT}/14_desktop_layout.png")
        print("✓ 14")
        await ctx.close()

        await browser.close()
        print(f"\n✅ All 14 screenshots saved to {OUT}/")

asyncio.run(main())
