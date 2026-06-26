"""
Download Douyin videos by intercepting the actual video URL from a real
browser session. Bypasses API signing requirements entirely.
"""
import asyncio
import re
import threading
from pathlib import Path
from typing import Callable

# Limit concurrent Chromium instances to avoid RAM exhaustion
_playwright_sem = threading.Semaphore(2)

_DESKTOP_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
)

_VIDEO_URL_RE = re.compile(
    r"https://[^\"'\s]+(?:v26-web\.douyinvod\.com|v[0-9]+-web\.douyinvod\.com"
    r"|v[0-9]+\.douyincdn\.com|bytedance\.com)[^\"'\s]*\.mp4[^\"'\s]*",
    re.IGNORECASE,
)

_CDN_HOSTS = (
    "douyinvod.com",
    "douyincdn.com",
    "bytedance.com",
    "amemv.com",
    "tiktokcdn.com",
    "musical.ly",
    "zjcdn.com",
    "byteeffecttos.com",
    "toutiaoimg.com",
    "pstatp.com",
    "snssdk.com",
    "ixigua.com",
    "iesdouyin.com",
    "byteimg.com",
)

_VIDEO_PATH_MARKERS = ("/video/tos/", "/video/", "mime_type=video", "video_mp4")


def _is_video_url(url: str) -> bool:
    if not any(h in url for h in _CDN_HOSTS):
        return False
    lower = url.lower()
    # exclude sticker/effect mp4s (small, under effectcdn paths)
    if "effectcdn" in lower or "ies.fe.effect" in lower:
        return False
    return ".mp4" in lower or any(m in url for m in _VIDEO_PATH_MARKERS)


async def _intercept_video_url(video_page_url: str, log: Callable, timeout_ms: int = 45_000) -> str:
    import sys
    from playwright.async_api import async_playwright, Request, Response

    found: list[str] = []

    # --no-sandbox / --disable-dev-shm-usage are Linux-only; omit on macOS/Windows
    base_args = ["--disable-blink-features=AutomationControlled", "--disable-infobars", "--window-size=1280,720"]
    if sys.platform == "linux":
        base_args += ["--no-sandbox", "--disable-dev-shm-usage", "--disable-setuid-sandbox"]

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True, args=base_args)
        ctx = await browser.new_context(
            user_agent=_DESKTOP_UA,
            viewport={"width": 1280, "height": 720},
            locale="zh-CN",
            timezone_id="Asia/Shanghai",
            extra_http_headers={"Accept-Language": "zh-CN,zh;q=0.9"},
        )
        await ctx.add_init_script("""
            Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
            Object.defineProperty(navigator, 'plugins', { get: () => [1, 2, 3] });
            window.chrome = { runtime: {} };
        """)

        def on_request(req: Request) -> None:
            url = req.url
            if _is_video_url(url) and url not in found:
                found.append(url)
                log(f"  Intercepted request: {url[:80]}...", "info")

        def on_response(resp: Response) -> None:
            url = resp.url
            ct = resp.headers.get("content-type", "")
            if ("video" in ct or "octet-stream" in ct) and url not in found:
                if _is_video_url(url) or any(h in url for h in _CDN_HOSTS):
                    found.append(url)
                    log(f"  Intercepted response: {url[:80]}...", "info")

        page = await ctx.new_page()
        page.on("request", on_request)
        page.on("response", on_response)

        # Pre-visit to get session cookies
        log("  Pre-visiting douyin.com...", "info")
        try:
            await page.goto("https://www.douyin.com", wait_until="domcontentloaded", timeout=15_000)
            await page.wait_for_timeout(3000)
        except Exception:
            pass

        log(f"  Navigating: {video_page_url}", "info")
        try:
            await page.goto(video_page_url, wait_until="domcontentloaded", timeout=timeout_ms)
        except Exception:
            pass

        # Wait for video element, then click to trigger play
        try:
            await page.wait_for_selector("video", timeout=10_000)
            await page.click("video")
            log("  Clicked video player.", "info")
            await page.wait_for_timeout(2000)
        except Exception:
            pass

        # Scroll to trigger lazy-load
        try:
            await page.evaluate("window.scrollBy(0, 300)")
            await page.wait_for_timeout(1000)
        except Exception:
            pass

        # Try pressing play via keyboard if no URL yet
        if not found:
            try:
                await page.keyboard.press("Space")
                await page.wait_for_timeout(2000)
            except Exception:
                pass

        # Wait up to 45s for CDN URL
        for _ in range(45):
            if found:
                break
            await page.wait_for_timeout(1000)

        # Fallback: scan page source for video URLs
        if not found:
            log("  No URL intercepted, scanning page source...", "info")
            try:
                html = await page.content()
                matches = _VIDEO_URL_RE.findall(html)
                found.extend(m for m in matches if m not in found)
            except Exception:
                pass

        # Fallback: extract src from <video> element
        if not found:
            log("  Checking video element src...", "info")
            try:
                src = await page.evaluate("""
                    () => {
                        const v = document.querySelector('video');
                        return v ? (v.src || v.currentSrc || '') : '';
                    }
                """)
                if src and src.startswith("http") and src not in found:
                    found.append(src)
                    log(f"  Got video src: {src[:80]}...", "info")
            except Exception:
                pass

        await browser.close()

    if not found:
        raise RuntimeError("Playwright: no video URL intercepted from Douyin page")

    # Prefer URLs without watermark (avoid 'playwm', prefer 'play')
    preferred = next((u for u in found if "playwm" not in u), found[0])
    return preferred


def _download_url(url: str, out_path: str, log: Callable) -> None:
    import httpx

    headers = {
        "User-Agent": _DESKTOP_UA,
        "Referer": "https://www.douyin.com/",
        "Accept": "*/*",
    }
    log(f"  Downloading video...", "info")
    with httpx.Client(headers=headers, follow_redirects=True, timeout=120) as client:
        with client.stream("GET", url, timeout=120) as resp:
            resp.raise_for_status()
            total = int(resp.headers.get("content-length", 0))
            downloaded = 0
            with open(out_path, "wb") as f:
                for chunk in resp.iter_bytes(chunk_size=1024 * 1024):
                    f.write(chunk)
                    downloaded += len(chunk)
                    if total:
                        log(f"  {int(downloaded / total * 100)}%", "info")


def download_via_playwright(url: str, out_dir: str, log: Callable) -> str:
    """
    Navigate to Douyin video page in headless Chromium, intercept the CDN
    video URL from network traffic, then stream-download it.
    """
    out_path = str(Path(out_dir) / "video.mp4")
    log("Trying Playwright browser intercept...", "info")

    with _playwright_sem:
        video_url = asyncio.run(_intercept_video_url(url, log))

    log(f"  Got video URL.", "info")
    _download_url(video_url, out_path, log)
    return out_path
