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
)

_VIDEO_PATH_MARKERS = ("/video/tos/", "/video/", "mime_type=video")


def _is_video_url(url: str) -> bool:
    if not any(h in url for h in _CDN_HOSTS):
        return False
    lower = url.lower()
    # exclude sticker/effect mp4s (small, under effectcdn paths)
    if "effectcdn" in lower or "ies.fe.effect" in lower:
        return False
    return ".mp4" in lower or any(m in url for m in _VIDEO_PATH_MARKERS)


async def _intercept_video_url(video_page_url: str, log: Callable, timeout_ms: int = 30_000) -> str:
    from playwright.async_api import async_playwright, Request

    found: list[str] = []

    async with async_playwright() as p:
        browser = await p.chromium.launch(
            headless=True,
            args=[
                "--disable-blink-features=AutomationControlled",
                "--no-sandbox",
                "--disable-dev-shm-usage",
                "--disable-setuid-sandbox",
                "--disable-infobars",
                "--window-size=1280,720",
            ],
        )
        ctx = await browser.new_context(
            user_agent=_DESKTOP_UA,
            viewport={"width": 1280, "height": 720},
            locale="zh-CN",
            timezone_id="Asia/Shanghai",
            extra_http_headers={
                "Accept-Language": "zh-CN,zh;q=0.9",
            },
        )
        # Hide automation signals
        await ctx.add_init_script("""
            Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
            Object.defineProperty(navigator, 'plugins', { get: () => [1, 2, 3] });
            window.chrome = { runtime: {} };
        """)

        def on_request(req: Request) -> None:
            url = req.url
            if _is_video_url(url):
                clean = url.split("?")[0] + ("?" + url.split("?")[1] if "?" in url else "")
                if clean not in found:
                    found.append(url)
                    log(f"  Intercepted video URL: {url[:80]}...", "info")

        page = await ctx.new_page()
        page.on("request", on_request)

        # Pre-visit homepage to get fresh session cookies (required by Douyin)
        log("  Pre-visiting douyin.com to get session cookies...", "info")
        try:
            await page.goto("https://www.douyin.com", wait_until="domcontentloaded", timeout=15_000)
            await page.wait_for_timeout(2000)
        except Exception:
            pass

        log(f"  Navigating: {video_page_url}", "info")
        try:
            await page.goto(video_page_url, wait_until="networkidle", timeout=timeout_ms)
        except Exception:
            pass  # timeout fine — video requests may already be in flight

        # Wait up to 30s for video player to request CDN URL
        for _ in range(30):
            if found:
                break
            await page.wait_for_timeout(1000)

        # If not found via intercept, try extracting from page HTML/JS
        if not found:
            log("  No URL intercepted, scanning page source...", "info")
            try:
                html = await page.content()
                matches = _VIDEO_URL_RE.findall(html)
                found.extend(m for m in matches if m not in found)
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
