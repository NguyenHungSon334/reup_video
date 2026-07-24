"""
Download Douyin videos by intercepting the actual video URL from a real
browser session. Bypasses API signing requirements entirely.
"""
import asyncio
import json
import re
import sys
import threading
from pathlib import Path
from typing import Callable

from backend.services.cancel import check as check_cancelled
from backend.services.progress import throttled

# One Douyin navigation at a time. Parallel navigations share one browser
# session, so they multiply anti-bot pressure (captcha walls, 504s) and each
# page installs a **/* route handler — three of those on the same context is
# where the flaky "no URL intercepted" runs came from. This is NOT the
# bottleneck: encoding is capped at 1 anyway, and the bytes are fetched
# outside the lock by httpx, so job N+1 still downloads while job N encodes.
_playwright_sem = threading.Semaphore(1)

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

# Live-stream endpoints. A Douyin video page embeds live previews in its
# sidebar, and those are served from the same CDN with a video content-type.
# Downloading one never finishes — the stream has no end and no content-length,
# so the job hangs forever while the temp file grows without bound.
_LIVE_MARKERS = ("pull-flv", "pull-hls", "live-push", "/stream-", ".flv", ".m3u8")


def _is_live_url(url: str) -> bool:
    lower = url.lower()
    return any(m in lower for m in _LIVE_MARKERS)

# Deterministic extractor: walk Douyin's embedded SSR state, find the object
# whose aweme_id == the requested id, and return ITS play addresses. Selecting by
# id (not network-capture order) is what prevents a recommended/sibling clip from
# being downloaded instead of the target.
_EXTRACT_BY_ID_JS = r"""
(targetId) => {
  const out = [];
  const seen = new Set();
  const push = (u) => {
    if (!u || typeof u !== 'string') return;
    let s = u.startsWith('//') ? 'https:' + u : u;
    if (s.startsWith('http')) out.push(s);
  };
  const collect = (v) => {
    if (!v) return;
    if (v.play_addr && Array.isArray(v.play_addr.url_list)) v.play_addr.url_list.forEach(push);
    if (typeof v.playApi === 'string') push(v.playApi);
    const pa = v.playAddr;
    if (pa) (Array.isArray(pa) ? pa : [pa]).forEach(p => push(typeof p === 'string' ? p : p && p.src));
    if (Array.isArray(v.bitRateList)) v.bitRateList.forEach(b => {
      const bp = b && b.playAddr;
      if (bp) (Array.isArray(bp) ? bp : [bp]).forEach(p => push(typeof p === 'string' ? p : p && p.src));
    });
  };
  const visit = (o) => {
    if (!o || typeof o !== 'object' || seen.has(o)) return;
    seen.add(o);
    const id = o.aweme_id || o.awemeId;
    if (id && String(id) === String(targetId) && o.video) collect(o.video);
    for (const k in o) { try { visit(o[k]); } catch (e) {} }
  };
  try { visit(window._ROUTER_DATA); } catch (e) {}
  for (const s of document.querySelectorAll('script')) {
    const t = s.textContent || '';
    if (t.indexOf(targetId) === -1) continue;
    if (t.indexOf('play_addr') === -1 && t.indexOf('playApi') === -1 && t.indexOf('playAddr') === -1) continue;
    try { visit(JSON.parse(t)); } catch (e) {}
  }
  return [...new Set(out)];
}
"""


def _extract_aweme_id(url: str) -> str | None:
    """Pull the target Douyin video id from the canonical page URL.

    Only id-bearing forms are accepted. A bare `\\d{15,20}` scan used to match
    any long number in the query string (device_id, timestamps, ttwid digits),
    producing a bogus target id that silently disabled every same-video guard.
    """
    for pat in (r"/video/(\d+)", r"modal_id=(\d+)", r"aweme_id=(\d+)"):
        m = re.search(pat, url)
        if m:
            return m.group(1)
    return None


def _pick_target_url(found: list[str]) -> str | None:
    """Choose the correct CDN URL from intercepted candidates.

    `found` is ordered by capture time; the target autoplays first, so earlier
    entries are the target (feed-advancing actions are disabled, so siblings
    should not appear). Among the target's own variants, prefer the
    watermark-free one ('play' over 'playwm'). Returns None if empty.
    """
    if not found:
        return None
    return next((u for u in found if "playwm" not in u), found[0])


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


def _save_cookies_json(cookies: list[dict], log: Callable) -> None:
    """Dump the live session cookies to JSON so the pure-API path can read them
    without launching a browser (the whole point of the fast path)."""
    from backend.config import COOKIES_JSON_FILE
    if not cookies:
        return
    try:
        COOKIES_JSON_FILE.parent.mkdir(parents=True, exist_ok=True)
        COOKIES_JSON_FILE.write_text(json.dumps(cookies), encoding="utf-8")
        log(f"  Saved {len(cookies)} cookies to {COOKIES_JSON_FILE.name}", "info")
    except Exception as e:
        log(f"  Cookie JSON save failed: {e}", "warn")


def load_cookie_header() -> str:
    """Cookie header string from the JSON store — no browser launch. Empty if
    the store is missing/unreadable (caller then seeds it via Playwright)."""
    from backend.config import COOKIES_JSON_FILE
    try:
        cookies = json.loads(COOKIES_JSON_FILE.read_text(encoding="utf-8"))
    except Exception:
        return ""
    return "; ".join(f"{c['name']}={c['value']}" for c in cookies if c.get("name"))


def _is_video_url(url: str) -> bool:
    if not any(h in url for h in _CDN_HOSTS):
        return False
    if _is_live_url(url):
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
        self._visible = False  # first seed runs visible so user can solve captcha

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

    async def _teardown(self) -> None:
        """Close the shared context + playwright driver, ignoring errors, so the
        next _ensure_browser() launches a clean one."""
        if self._ctx is not None:
            try:
                await self._ctx.close()
            except Exception:
                pass
        self._ctx = None
        self._browser = None
        if self._pw is not None:
            try:
                await self._pw.stop()
            except Exception:
                pass
            self._pw = None

    async def _new_page(self, log: Callable):
        """Open a page on the shared browser, relaunching it once if it died.

        launch_persistent_context() leaves BrowserContext.browser as None, so the
        liveness check in _ensure_browser can never observe a crashed Chromium:
        every later download would fail with 'Target closed' until the whole app
        was restarted. Opening the page IS the liveness probe.
        """
        await self._ensure_browser(log)
        try:
            return await self._ctx.new_page()
        except Exception as exc:
            log(f"  Shared browser is dead ({exc}) — relaunching...", "warn")
            await self._teardown()
            await self._ensure_browser(log)
            return await self._ctx.new_page()

    async def _ensure_browser(self, log: Callable) -> None:
        if self._browser_lock is None:
            self._browser_lock = asyncio.Lock()
        async with self._browser_lock:
            if self._ctx is not None:
                br = self._ctx.browser
                if br is None or br.is_connected():
                    return
                self._ctx = None
            from playwright.async_api import async_playwright

            base_args = ["--disable-blink-features=AutomationControlled",
                         "--disable-infobars", "--window-size=1280,720"]
            if sys.platform == "linux":
                base_args += ["--no-sandbox", "--disable-dev-shm-usage",
                              "--disable-setuid-sandbox"]

            # Persistent context: cookies/session survive across runs, so Douyin's
            # anti-bot (ttwid/captcha) is satisfied once and reused — far fewer
            # blocks than a fresh context every launch. Stored in the user's home
            # (writable; the app bundle itself is read-only on macOS).
            user_data_dir = Path.home() / ".reup_video" / "pw_userdata"
            user_data_dir.mkdir(parents=True, exist_ok=True)

            log("  Launching shared Chromium (persistent profile)...", "info")
            self._pw = await async_playwright().start()
            self._ctx = await self._pw.chromium.launch_persistent_context(
                str(user_data_dir),
                headless=not self._visible,
                args=base_args,
                user_agent=_DESKTOP_UA,
                viewport={"width": 1280, "height": 720},
                locale="zh-CN",
                timezone_id="Asia/Shanghai",
                extra_http_headers={"Accept-Language": "zh-CN,zh;q=0.9"},
            )
            self._browser = self._ctx.browser
            await self._ctx.add_init_script("""
                Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
                Object.defineProperty(navigator, 'plugins', { get: () => [1, 2, 3] });
                window.chrome = { runtime: {} };
            """)

            # Inject the user's saved cookies (pasted in Settings) so the browser
            # is actually logged in — otherwise it's a guest session and Douyin's
            # anti-bot returns "fresh cookies needed" / drifts to a feed page.
            await self._inject_saved_cookies(log)

            # Warm-up: visit douyin.com first so the logged-in session is
            # established on the origin before we hit the video page. Skipping this
            # left a cold direct-nav that never hydrated / never fired the
            # aweme/detail XHR → "no video URL intercepted". Keep it.
            warm = await self._ctx.new_page()
            log("  Pre-visiting douyin.com (one-time warm-up)...", "info")
            try:
                await warm.goto("https://www.douyin.com",
                                wait_until="domcontentloaded", timeout=15_000)
                await warm.wait_for_timeout(20_000 if self._visible else 3000)
                cookies = await self._ctx.cookies()
                _save_cookies(cookies, log)       # Netscape, for yt-dlp
                _save_cookies_json(cookies, log)  # JSON, for pure-API
            except Exception as e:
                log(f"  Warm-up skipped: {e}", "warn")
            finally:
                await warm.close()

    async def _inject_saved_cookies(self, log: Callable) -> set[str]:
        """Load cookies from the JSON store (seeded by the Settings paste box) into
        the browser context so the session is authenticated. Pasted cookies carry
        only name/value, so default the domain/path to .douyin.com. Returns the set
        of injected cookie names so the caller can skip warm-up when ttwid is set."""
        from backend.config import COOKIES_JSON_FILE
        try:
            saved = json.loads(COOKIES_JSON_FILE.read_text(encoding="utf-8"))
        except Exception:
            return set()
        pw_cookies = []
        for c in saved:
            name, value = c.get("name"), c.get("value")
            if not name:
                continue
            # Force progressive MP4 delivery: a logged-in DASH account (is_dash_user=1)
            # makes Douyin serve segmented .m4s over MPD, which none of our extractors
            # (network .mp4 / play_addr url_list) can grab → "no URL intercepted".
            if name == "is_dash_user":
                value = "0"
            pw_cookies.append({
                "name": name,
                "value": str(value),
                "domain": c.get("domain") or ".douyin.com",
                "path": c.get("path") or "/",
            })
        if not pw_cookies:
            return set()
        # add_cookies is atomic: one malformed cookie rejects the whole batch
        # ("Invalid cookie fields"). Try the batch first, then fall back to
        # per-cookie so a single bad entry can't drop the login cookies.
        try:
            await self._ctx.add_cookies(pw_cookies)
            ok = {c["name"] for c in pw_cookies}
        except Exception:
            ok = set()
            for c in pw_cookies:
                try:
                    await self._ctx.add_cookies([c])
                    ok.add(c["name"])
                except Exception as e:
                    log(f"  Skipped bad cookie {c['name']}: {e}", "warn")
        if ok:
            log(f"  Injected {len(ok)}/{len(pw_cookies)} saved cookies "
                "(logged-in session).", "info")
        return ok

    async def _is_gateway_error(self, page) -> bool:
        """Douyin's edge sometimes returns a bare '504 Gateway Time-out' (or 502/
        429) page instead of the video — a transient throttle, not a cookie/captcha
        issue. Detect it by title so we can retry the nav rather than give up."""
        try:
            title = await page.title()
        except Exception:
            return False
        t = title.lower()
        return any(s in t for s in ("504 gateway", "502 bad gateway",
                                    "gateway time-out", "429", "too many requests"))

    async def _is_captcha_page(self, page) -> bool:
        """Douyin serves a '验证码中间页' verify wall instead of the video when its
        anti-bot trips. Detect it by title/URL so we can hand it to the user."""
        try:
            title = await page.title()
        except Exception:
            title = ""
        if "验证码" in title or "verify" in title.lower():
            return True
        u = page.url.lower()
        return "captcha" in u or "verifycenter" in u or "/verify" in u

    async def _go_visible(self, log: Callable) -> None:
        """Tear down the (headless) context and relaunch a VISIBLE window so the
        user can solve a captcha. Current window stays visible; the next auto
        launch reverts to headless."""
        await self._teardown()
        self._visible = True
        try:
            await self._ensure_browser(log)
        finally:
            self._visible = False

    async def _wait_captcha_cleared(self, page, video_url: str, log: Callable,
                                    timeout_s: int = 180) -> None:
        """Block while the user solves the captcha in the visible window. Once the
        verify page clears, make sure we're back on the target video, then return.
        The persistent profile keeps the verify token, so later downloads skip it."""
        log("  Solve the captcha in the browser window — waiting up to 3 min...", "warn")
        tid = _extract_aweme_id(video_url)
        for _ in range(timeout_s):
            await page.wait_for_timeout(1000)
            if not await self._is_captcha_page(page):
                if tid and tid not in page.url:
                    try:
                        await page.goto(video_url, wait_until="domcontentloaded",
                                        timeout=20_000)
                    except Exception:
                        pass
                    # a fresh nav can bounce back to captcha; re-check once
                    if await self._is_captcha_page(page):
                        continue
                log("  Captcha cleared — continuing download.", "info")
                return
        raise RuntimeError("Captcha not solved in time (Douyin verify wall)")

    async def _fetch(self, video_page_url: str, log: Callable, timeout_ms: int = 45_000) -> str:
        await self._ensure_browser(log)
        from playwright.async_api import Request, Response, Route

        target_id = _extract_aweme_id(video_page_url)
        found: list[str] = []
        # play_addr from the aweme/detail API, keyed by the aweme_id it belongs
        # to. Keyed (not a flat list) because a detail response can arrive before
        # a short link has resolved to its id — filtering happens at use time.
        detail_by_id: dict[str, list[str]] = {}
        api_hits: list[str] = []     # diagnostics: aweme API + CDN requests seen

        async def on_detail(resp: "Response") -> None:
            # Most reliable source: Douyin's own detail API returns the exact
            # play_addr for a specific aweme_id. Storing per-id is what stops a
            # feed-prefetched detail call from handing us a recommended clip.
            if "aweme/detail" not in resp.url:
                return
            try:
                data = json.loads(await resp.text())
            except Exception:
                return
            ad = data.get("aweme_detail") or {}
            aid = str(ad.get("aweme_id") or "")
            if not aid:
                return
            urls = ((ad.get("video") or {}).get("play_addr") or {}).get("url_list") or []
            bucket = detail_by_id.setdefault(aid, [])
            for u in urls:
                if u and u not in bucket:
                    bucket.append(u)
            if bucket:
                log(f"  Got play_addr from aweme/detail API ({aid}).", "info")

        def on_request_dbg(req: "Request") -> None:
            url = req.url
            if "/aweme/" in url or any(h in url for h in _CDN_HOSTS):
                if url not in api_hits:
                    api_hits.append(url)

        def on_request(req: "Request") -> None:
            url = req.url
            if _is_video_url(url) and url not in found:
                found.append(url)
                log(f"  Intercepted request: {url[:80]}...", "info")

        def on_response(resp: "Response") -> None:
            url = resp.url
            ct = resp.headers.get("content-type", "")
            if ("video" in ct or "octet-stream" in ct) and url not in found:
                if _is_live_url(url):
                    return  # live FLV/HLS preview, not the target clip
                if _is_video_url(url) or any(h in url for h in _CDN_HOSTS):
                    found.append(url)
                    log(f"  Intercepted response: {url[:80]}...", "info")

        async def block_extra_videos(route: "Route") -> None:
            # Capture the URL string (the listener already did), then abort any
            # video CDN request beyond the first — this kills recommended/feed
            # prefetch so a sibling video can never be downloaded. We never need
            # the bytes in-browser; the file is fetched separately via httpx.
            url = route.request.url
            if _is_video_url(url) and found and url != found[0]:
                try:
                    await route.abort()
                    return
                except Exception:
                    pass
            try:
                await route.continue_()
            except Exception:
                pass

        async def open_and_nav():
            # Direct navigation to the target only — no homepage feed to confuse
            # interception (cookies already warm on the shared context).
            p = await self._new_page(log)
            p.on("response", on_detail)
            p.on("request", on_request)
            p.on("request", on_request_dbg)
            p.on("response", on_response)
            await p.route("**/*", block_extra_videos)
            log(f"  Navigating: {video_page_url}", "info")
            try:
                await p.goto(video_page_url, wait_until="domcontentloaded", timeout=timeout_ms)
            except Exception:
                pass
            return p

        page = await open_and_nav()
        try:
            # Gateway 504/502/429: Douyin edge throttled us and served an error
            # page (0 requests, no video). Back off and re-navigate a few times —
            # these clear on retry far more often than not.
            for attempt in range(3):
                if not await self._is_gateway_error(page):
                    break
                log(f"  Douyin edge returned gateway error — retrying "
                    f"({attempt + 1}/3)...", "warn")
                await page.close()
                await asyncio.sleep(4 + attempt * 4)  # 4s, 8s, 12s backoff
                page = await open_and_nav()

            # Captcha wall ('验证码中间页'): Douyin redirects to a verify page instead
            # of the video. Can't solve headless — relaunch a visible window, let the
            # user solve it, then re-navigate on the fresh (now-trusted) session.
            if await self._is_captcha_page(page):
                log("  Captcha wall detected — opening browser window to solve.", "warn")
                await page.close()
                await self._go_visible(log)
                page = await open_and_nav()
                await self._wait_captcha_cleared(page, video_page_url, log)

            # A short v.douyin.com link that didn't resolve upstream has no id
            # yet — take it from the page Douyin redirected us to. Without this
            # every same-video guard below silently switched off and whatever the
            # feed happened to autoplay got downloaded instead of the target.
            if not target_id:
                target_id = _extract_aweme_id(page.url)
                if not target_id:
                    raise RuntimeError(
                        f"Không xác định được aweme_id của video (url={page.url[:80]}) "
                        "— từ chối tải để tránh nhầm sang clip gợi ý")
                log(f"  Target aweme_id resolved from page URL: {target_id}", "info")

            # Guard: confirm we actually landed on the requested video, not a
            # redirect to a feed/recommended page. Anything captured on a drifted
            # page is a recommended/feed clip — accepting it downloads the WRONG
            # video, so reject outright rather than "trusting" it.
            if target_id not in page.url:
                raise RuntimeError(
                    f"Playwright drifted to {page.url[:80]} (target {target_id}); "
                    "refusing to download a non-target clip")

            # Deterministic paths (both keyed to the exact aweme_id, so a
            # sibling/recommended clip can never be selected): prefer the play_addr
            # from the aweme/detail API response, then the embedded SSR state. Retry
            # while the page hydrates; fall through to network interception only if
            # neither appears.
            if target_id:
                for _ in range(8):
                    url = _pick_target_url(detail_by_id.get(target_id, []))
                    if url:
                        return url
                    try:
                        by_id = await page.evaluate(_EXTRACT_BY_ID_JS, target_id)
                    except Exception:
                        by_id = []
                    if by_id:
                        url = _pick_target_url(by_id)
                        if url:
                            log(f"  Matched play URL by aweme_id {target_id}.", "info")
                            return url
                    await page.wait_for_timeout(1000)

            # Trigger playback IN PLACE. No scroll / no Space — those advance the
            # vertical feed to the next video and would intercept the wrong clip.
            try:
                await page.wait_for_selector("video", timeout=10_000)
                await page.click("video")
                log("  Clicked video player.", "info")
                await page.wait_for_timeout(2000)
            except Exception:
                pass

            # Wait for interception; stop early once we have a watermark-free URL.
            for _ in range(45):
                if any("playwm" not in u for u in found):
                    break
                if found:
                    # Have a (watermarked) target URL — short grace for the clean
                    # variant, then accept what we have.
                    await page.wait_for_timeout(1000)
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
                        " return v ? (v.currentSrc || v.src || '') : ''; }")
                    # MSE players expose a blob: URL that can't be downloaded —
                    # only accept a real http(s) source here.
                    if src and src.startswith("http") and src not in found:
                        found.append(src)
                        log(f"  Got video src: {src[:80]}...", "info")
                except Exception:
                    pass
            # Diagnostics on failure: reveal what Douyin actually served so we can
            # tell "page blocked" (no media at all) from "DASH/blob" (media but
            # unusable format) from "wrong extractor" (data present, we missed it).
            if not found and not detail_by_id:
                try:
                    title = await page.title()
                except Exception:
                    title = "?"
                try:
                    vinfo = await page.evaluate(
                        "() => { const v = document.querySelector('video');"
                        " return v ? {count: document.querySelectorAll('video').length,"
                        " src: (v.currentSrc||v.src||'').slice(0,60)} : {count: 0, src: ''}; }")
                except Exception:
                    vinfo = {"count": 0, "src": ""}
                cdn = [u for u in api_hits if any(h in u for h in _CDN_HOSTS)]
                log(f"  [dbg] FAIL url={page.url[:90]}", "warn")
                log(f"  [dbg] title={title!r} video={vinfo}", "warn")
                log(f"  [dbg] api/CDN requests seen={len(api_hits)}, CDN media={len(cdn)}", "warn")
                for u in api_hits[:12]:
                    log(f"  [dbg] hit: {u[:110]}", "warn")
        finally:
            await page.close()  # free the tab; browser stays alive for reuse

        url = _pick_target_url(found)
        if not url:
            raise RuntimeError("Playwright: no video URL intercepted from Douyin page")
        return url

    def fetch_video_url(self, url: str, log: Callable, timeout: float = 260) -> str:
        self._ensure_loop()
        fut = asyncio.run_coroutine_threadsafe(self._fetch(url, log), self._loop)
        return fut.result(timeout=timeout)

    async def _cookie_header(self) -> str:
        try:
            cookies = await self._ctx.cookies()
        except Exception:
            return ""
        return "; ".join(
            f"{c['name']}={c['value']}" for c in cookies if c.get("name"))

    def cookie_header(self) -> str:
        """Cookie string from the live browser context, so the httpx download
        request carries the same anti-bot cookies (ttwid etc.) Douyin's CDN
        expects — matching what the browser itself used."""
        self._ensure_loop()
        if self._loop is None:
            return ""
        try:
            return asyncio.run_coroutine_threadsafe(
                self._cookie_header(), self._loop).result(timeout=15)
        except Exception:
            return ""

    async def _seed_visible(self, log: Callable) -> None:
        """Tear down any running (likely headless) browser and relaunch a VISIBLE
        window so the user can log in / solve a captcha, then save cookies. Used
        by the Settings "Get cookies" button — explicit, manual, one at a time."""
        await self._teardown()
        self._visible = True
        try:
            await self._ensure_browser(log)  # visible launch + warm-up saves JSON
        finally:
            self._visible = False  # later auto-launches stay headless


_worker = _BrowserWorker()


# Backstops for a response that never ends. A short clip is a few tens of MB and
# takes seconds; an endless live stream sends data forever, so neither the read
# timeout (bytes keep arriving) nor content-length (absent) ever stops it.
_MAX_DOWNLOAD_BYTES = 600 * 1024 * 1024
_MAX_DOWNLOAD_SECONDS = 600


def _download_url(url: str, out_path: str, log: Callable, cookie: str = "") -> None:
    import time

    import httpx

    if _is_live_url(url):
        raise RuntimeError(f"URL là luồng live, không phải video: {url[:80]}")

    headers = {
        "User-Agent": _DESKTOP_UA,
        "Referer": "https://www.douyin.com/",
        "Accept": "*/*",
    }
    if cookie:
        headers["Cookie"] = cookie
    log(f"  Downloading video...", "info")
    emit = throttled(log)
    deadline = time.monotonic() + _MAX_DOWNLOAD_SECONDS
    with httpx.Client(headers=headers, follow_redirects=True, timeout=120) as client:
        with client.stream("GET", url, timeout=120) as resp:
            resp.raise_for_status()
            total = int(resp.headers.get("content-length", 0))
            if total > _MAX_DOWNLOAD_BYTES:
                raise RuntimeError(f"Video quá lớn ({total // 1024 // 1024} MB)")
            downloaded = 0
            with open(out_path, "wb") as f:
                for chunk in resp.iter_bytes(chunk_size=1024 * 1024):
                    check_cancelled()
                    f.write(chunk)
                    downloaded += len(chunk)
                    if downloaded > _MAX_DOWNLOAD_BYTES:
                        raise RuntimeError(
                            f"Tải quá {_MAX_DOWNLOAD_BYTES // 1024 // 1024} MB mà chưa hết "
                            "— nhiều khả năng là luồng live, đã dừng")
                    if time.monotonic() > deadline:
                        raise RuntimeError(
                            f"Tải quá {_MAX_DOWNLOAD_SECONDS}s chưa xong — đã dừng")
                    if total:
                        pct = downloaded / total * 100
                        emit(f"  {int(pct)}%", "info", pct=pct)
                    else:
                        emit(f"  {downloaded // 1024 // 1024} MB", "info")


def seed_cookies(log: Callable) -> None:
    """Open a VISIBLE browser to (re)seed the cookie JSON — manual Settings action.
    Blocks while the window is open so the user can solve captcha / scan QR."""
    worker = _worker
    worker._ensure_loop()
    asyncio.run_coroutine_threadsafe(worker._seed_visible(log), worker._loop).result(timeout=180)


def ensure_cookies(log: Callable) -> bool:
    """Auto-acquire Douyin cookies HEADLESS (no manual paste, no window).

    Warming the shared browser runs a guest visit to douyin.com, which harvests
    ttwid/__ac_nonce and saves them to the JSON store — enough to download PUBLIC
    videos. Only returns False if even the guest handshake produced no cookies
    (network down / hard block); then the caller can fall back to manual paste.
    """
    if load_cookie_header():
        return True
    log("Chưa có cookie — tự động lấy cookie khách (headless)...", "info")
    _worker._ensure_loop()
    try:
        asyncio.run_coroutine_threadsafe(
            _worker._ensure_browser(log), _worker._loop).result(timeout=120)
    except Exception as e:
        log(f"  Auto cookie failed: {e}", "warn")
    return bool(load_cookie_header())


def download_via_playwright(url: str, out_dir: str, log: Callable) -> str:
    """
    Navigate to a Douyin video page in the shared headless Chromium, intercept
    the CDN video URL from network traffic, then stream-download it.
    """
    out_path = str(Path(out_dir) / "video.mp4")
    log("Trying Playwright browser intercept...", "info")

    with _playwright_sem:  # bound concurrent pages on the shared browser
        video_url = _worker.fetch_video_url(url, log)
        cookie = _worker.cookie_header()

    log(f"  Got video URL.", "info")
    _download_url(video_url, out_path, log, cookie)
    return out_path


if __name__ == "__main__":
    # Offline self-check for the pure selection logic (no browser / network).
    assert _extract_aweme_id("https://www.douyin.com/video/7412345678901234567") \
        == "7412345678901234567"
    assert _extract_aweme_id("https://v.douyin.com/abc/") is None
    assert _extract_aweme_id("https://www.douyin.com/user/x?modal_id=7412345678901234567") \
        == "7412345678901234567"
    # A long number that is NOT an id must never be mistaken for the target —
    # a bogus id disables every same-video guard.
    assert _extract_aweme_id("https://www.douyin.com/?device_id=1234567890123456") is None

    # A Douyin video page embeds live previews served from the same CDN with a
    # video content-type. Picking one downloads forever (no end, no length).
    _live = "https://pull-flv-q26.douyincdn.com/third/stream-119775483729543997_or4.flv"
    _hls = "https://pull-hls-f26.douyincdn.com/third/stream-123.m3u8"
    _clip = "https://v26-web.douyinvod.com/abc/play/x.mp4?a=1"
    assert _is_live_url(_live) and _is_live_url(_hls) and not _is_live_url(_clip)
    assert not _is_video_url(_live) and not _is_video_url(_hls)
    assert _is_video_url(_clip)
    try:
        _download_url(_live, "unused.mp4", lambda *a, **k: None)
        raise AssertionError("live URL must be refused before opening a socket")
    except RuntimeError as e:
        assert "live" in str(e), e

    # First-captured wins; among target variants prefer the clean ('play') one.
    wm   = "https://v26-web.douyinvod.com/aaa/playwm/x.mp4"
    clean = "https://v26-web.douyinvod.com/aaa/play/x.mp4"
    assert _pick_target_url([wm, clean]) == clean          # prefer non-watermark
    assert _pick_target_url([wm]) == wm                    # only watermarked → use it
    assert _pick_target_url([clean]) == clean
    assert _pick_target_url([]) is None

    # Cookie-header builder reads the JSON store and joins name=value pairs.
    import tempfile
    from backend import config as _cfg
    _cfg.COOKIES_JSON_FILE = Path(tempfile.mkdtemp()) / "c.json"
    _cfg.COOKIES_JSON_FILE.write_text(
        json.dumps([{"name": "ttwid", "value": "abc"},
                    {"name": "sid", "value": "xyz"}, {"value": "noname"}]),
        encoding="utf-8")
    assert load_cookie_header() == "ttwid=abc; sid=xyz"
    print("OK — playwright_downloader selection self-check passed")
