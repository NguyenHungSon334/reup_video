"""
Download Douyin videos by intercepting the actual video URL from a real
browser session. Bypasses API signing requirements entirely.
"""
import asyncio
import re
import sys
import threading
from pathlib import Path
from typing import Callable

from backend.services.progress import throttled

# Limit concurrent pages open at once on the shared browser (RAM guard)
_playwright_sem = threading.Semaphore(3)

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


def _save_cookies(cookies: list[dict], log: Callable) -> None:
    """Export Playwright session cookies to Netscape format for yt-dlp.

    Always overwrites: reaching the Playwright fallback means yt-dlp's cookies
    were insufficient ("fresh cookies needed"), so these fresh guest cookies
    (ttwid etc. from the pre-visit) replace whatever was stale.
    """
    import time
    from backend.config import COOKIES_STORE_FILE

    if not cookies:
        return

    lines = ["# Netscape HTTP Cookie File\n"]
    for c in cookies:
        domain = c.get("domain", "")
        if not domain:
            continue
        sub = "TRUE" if domain.startswith(".") else "FALSE"
        secure = "TRUE" if c.get("secure") else "FALSE"
        expiry = int(c.get("expires", 0) or 0)
        if expiry <= 0:  # session cookie → give it a 1-day life
            expiry = int(time.time()) + 86400
        lines.append(
            "\t".join([domain, sub, c.get("path", "/"), secure,
                       str(expiry), c.get("name", ""), c.get("value", "")]) + "\n"
        )

    COOKIES_STORE_FILE.write_text("".join(lines), encoding="utf-8")
    log(f"  Saved {len(cookies)} cookies to {COOKIES_STORE_FILE.name}", "info")


def _is_video_url(url: str) -> bool:
    if not any(h in url for h in _CDN_HOSTS):
        return False
    lower = url.lower()
    # exclude sticker/effect mp4s (small, under effectcdn paths)
    if "effectcdn" in lower or "ies.fe.effect" in lower:
        return False
    return ".mp4" in lower or any(m in url for m in _VIDEO_PATH_MARKERS)


class _BrowserWorker:
    """One persistent Chromium on a dedicated event-loop thread.

    Launching a browser per download (full launch + 3s douyin.com pre-visit)
    was the dominant cost and a likely cause of resource spikes. Instead we keep
    a single warmed browser+context alive and open a fresh page per video, so
    each download is just navigate + intercept. The loop lives on its own thread
    because uvicorn installs a Selector policy that can't spawn subprocesses on
    Windows — so we own a ProactorEventLoop here.
    """

    def __init__(self) -> None:
        self._loop: asyncio.AbstractEventLoop | None = None
        self._start_lock = threading.Lock()
        self._started = False
        self._pw = None
        self._browser = None
        self._ctx = None
        self._browser_lock: asyncio.Lock | None = None

    def _ensure_loop(self) -> None:
        with self._start_lock:
            if self._started:
                return
            ready = threading.Event()

            def _run() -> None:
                loop = asyncio.ProactorEventLoop() if sys.platform == "win32" \
                    else asyncio.new_event_loop()
                asyncio.set_event_loop(loop)
                self._loop = loop
                ready.set()
                loop.run_forever()

            threading.Thread(target=_run, daemon=True, name="playwright-loop").start()
            ready.wait()
            self._started = True

    async def _ensure_browser(self, log: Callable) -> None:
        if self._browser_lock is None:
            self._browser_lock = asyncio.Lock()
        async with self._browser_lock:
            if self._browser is not None and self._browser.is_connected():
                return
            from playwright.async_api import async_playwright

            base_args = ["--disable-blink-features=AutomationControlled",
                         "--disable-infobars", "--window-size=1280,720"]
            if sys.platform == "linux":
                base_args += ["--no-sandbox", "--disable-dev-shm-usage",
                              "--disable-setuid-sandbox"]

            log("  Launching shared Chromium...", "info")
            self._pw = await async_playwright().start()
            self._browser = await self._pw.chromium.launch(headless=True, args=base_args)
            self._ctx = await self._browser.new_context(
                user_agent=_DESKTOP_UA,
                viewport={"width": 1280, "height": 720},
                locale="zh-CN",
                timezone_id="Asia/Shanghai",
                extra_http_headers={"Accept-Language": "zh-CN,zh;q=0.9"},
            )
            await self._ctx.add_init_script("""
                Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
                Object.defineProperty(navigator, 'plugins', { get: () => [1, 2, 3] });
                window.chrome = { runtime: {} };
            """)

            # One-time warm-up: get ttwid/guest cookies, then save for yt-dlp.
            warm = await self._ctx.new_page()
            log("  Pre-visiting douyin.com (one-time warm-up)...", "info")
            try:
                await warm.goto("https://www.douyin.com",
                                wait_until="domcontentloaded", timeout=15_000)
                await warm.wait_for_timeout(3000)
                _save_cookies(await self._ctx.cookies(), log)
            except Exception as e:
                log(f"  Warm-up skipped: {e}", "warn")
            finally:
                await warm.close()

    async def _fetch(self, video_page_url: str, log: Callable, timeout_ms: int = 45_000) -> str:
        await self._ensure_browser(log)
        from playwright.async_api import Request, Response

        found: list[str] = []

        def on_request(req: "Request") -> None:
            url = req.url
            if _is_video_url(url) and url not in found:
                found.append(url)
                log(f"  Intercepted request: {url[:80]}...", "info")

        def on_response(resp: "Response") -> None:
            url = resp.url
            ct = resp.headers.get("content-type", "")
            if ("video" in ct or "octet-stream" in ct) and url not in found:
                if _is_video_url(url) or any(h in url for h in _CDN_HOSTS):
                    found.append(url)
                    log(f"  Intercepted response: {url[:80]}...", "info")

        page = await self._ctx.new_page()
        page.on("request", on_request)
        page.on("response", on_response)
        try:
            # Direct navigation to the target only — no homepage feed to confuse
            # interception (cookies already warm on the shared context).
            log(f"  Navigating: {video_page_url}", "info")
            try:
                await page.goto(video_page_url, wait_until="domcontentloaded", timeout=timeout_ms)
            except Exception:
                pass

            try:
                await page.wait_for_selector("video", timeout=10_000)
                await page.click("video")
                log("  Clicked video player.", "info")
                await page.wait_for_timeout(2000)
            except Exception:
                pass

            try:
                await page.evaluate("window.scrollBy(0, 300)")
                await page.wait_for_timeout(1000)
            except Exception:
                pass

            if not found:
                try:
                    await page.keyboard.press("Space")
                    await page.wait_for_timeout(2000)
                except Exception:
                    pass

            for _ in range(45):
                if found:
                    break
                await page.wait_for_timeout(1000)

            if not found:
                log("  No URL intercepted, scanning page source...", "info")
                try:
                    html = await page.content()
                    found.extend(m for m in _VIDEO_URL_RE.findall(html) if m not in found)
                except Exception:
                    pass

            if not found:
                log("  Checking video element src...", "info")
                try:
                    src = await page.evaluate(
                        "() => { const v = document.querySelector('video');"
                        " return v ? (v.src || v.currentSrc || '') : ''; }")
                    if src and src.startswith("http") and src not in found:
                        found.append(src)
                        log(f"  Got video src: {src[:80]}...", "info")
                except Exception:
                    pass
        finally:
            await page.close()  # free the tab; browser stays alive for reuse

        if not found:
            raise RuntimeError("Playwright: no video URL intercepted from Douyin page")

        # Prefer URLs without watermark (avoid 'playwm', prefer 'play')
        return next((u for u in found if "playwm" not in u), found[0])

    def fetch_video_url(self, url: str, log: Callable, timeout: float = 120) -> str:
        self._ensure_loop()
        fut = asyncio.run_coroutine_threadsafe(self._fetch(url, log), self._loop)
        return fut.result(timeout=timeout)


_worker = _BrowserWorker()


def _download_url(url: str, out_path: str, log: Callable) -> None:
    import httpx

    headers = {
        "User-Agent": _DESKTOP_UA,
        "Referer": "https://www.douyin.com/",
        "Accept": "*/*",
    }
    log(f"  Downloading video...", "info")
    emit = throttled(log)
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
                        pct = downloaded / total * 100
                        emit(f"  {int(pct)}%", "info", pct=pct)


def download_via_playwright(url: str, out_dir: str, log: Callable) -> str:
    """
    Navigate to a Douyin video page in the shared headless Chromium, intercept
    the CDN video URL from network traffic, then stream-download it.
    """
    out_path = str(Path(out_dir) / "video.mp4")
    log("Trying Playwright browser intercept...", "info")

    with _playwright_sem:  # bound concurrent pages on the shared browser
        video_url = _worker.fetch_video_url(url, log)

    log(f"  Got video URL.", "info")
    _download_url(video_url, out_path, log)
    return out_path
