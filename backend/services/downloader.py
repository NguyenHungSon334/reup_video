import re
import sys
from pathlib import Path
from typing import Callable

# macOS app bundle per yt-dlp browser keyword — used to skip cookie sources for
# browsers that aren't actually installed (trying chrome on a Mac without Chrome
# just fails and, with no cookie file yet, pushes us onto the drift-prone
# Playwright path that can grab the wrong clip).
_MAC_BROWSER_APPS: dict[str, str] = {
    "chrome":   "/Applications/Google Chrome.app",
    "chromium": "/Applications/Chromium.app",
    "safari":   "/Applications/Safari.app",
    "firefox":  "/Applications/Firefox.app",
    "edge":     "/Applications/Microsoft Edge.app",
}


def _browser_cookie_sources() -> list[str]:
    """Browser cookie sources to try, per platform — installed browsers only.

    Windows: skipped — Chrome 127+ app-bound encryption makes cookiesfrombrowser
    fail with DPAPI errors; the auto-saved douyin.cookies.txt is used instead.
    """
    if sys.platform == "win32":
        return []
    if sys.platform == "darwin":
        return [b for b in ("chrome", "chromium", "safari", "firefox")
                if Path(_MAC_BROWSER_APPS[b]).exists()]
    return ["chrome", "chromium", "firefox", "edge"]

import httpx

from backend.services.progress import throttled

_MOBILE_UA = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
)
_HEADERS = {
    "User-Agent": _MOBILE_UA,
    "Referer":    "https://www.douyin.com/",
}


def _normalize_url(url: str) -> str:
    m = re.search(r'/(?:share/)?video/(\d{15,20})', url)
    if m:
        return f"https://www.douyin.com/video/{m.group(1)}"
    return url


def _extract_video_id(url: str) -> str | None:
    for pattern in (r"/video/(\d+)", r"aweme_id=(\d+)", r"/(\d{15,19})"):
        m = re.search(pattern, url)
        if m:
            return m.group(1)
    return None


def _resolve_canonical(url: str, log: Callable) -> str:
    canonical = _normalize_url(url)
    if canonical != url:
        log(f"  Canonical: {canonical}", "info")
        return canonical

    log("  Resolving short URL...", "info")
    try:
        with httpx.Client(headers=_HEADERS, follow_redirects=True, timeout=15) as c:
            resp = c.get(url)
            long_url = str(resp.url)
            log(f"  Redirected: {long_url[:80]}", "info")
            canonical = _normalize_url(long_url)
            if canonical != long_url:
                log(f"  Canonical: {canonical}", "info")
                return canonical
            vid_id = _extract_video_id(long_url)
            if vid_id:
                canonical = f"https://www.douyin.com/video/{vid_id}"
                log(f"  Canonical: {canonical}", "info")
                return canonical
    except Exception as e:
        log(f"  Resolve failed: {e}", "warn")

    return url


def _ytdlp(
    url: str,
    out_dir: str,
    log: Callable,
    cookies_file: str | None = None,
    cookies_from_browser: str | None = None,
) -> str:
    import yt_dlp

    tpl = str(Path(out_dir) / "video.%(ext)s")
    emit = throttled(log)

    def _progress(d: dict) -> None:
        if d.get("status") == "downloading":
            pct_str = d.get("_percent_str", "").strip()
            speed = d.get("_speed_str", "").strip()
            if pct_str:
                pct = float(re.sub(r"[^\d.]", "", pct_str) or 0)
                emit(f"  {pct_str} {speed}".strip(), "info", pct=pct)
        elif d.get("status") == "finished":
            log(f"  Finished: {Path(d.get('filename', '')).name}", "info")

    ydl_opts: dict = {
        "outtmpl": tpl,
        "noplaylist": True,
        "merge_output_format": "mp4",
        "http_headers": {
            "Referer": "https://www.douyin.com",
            "User-Agent": _MOBILE_UA,
        },
        "progress_hooks": [_progress],
        "quiet": True,
        "no_warnings": True,
    }
    if cookies_file and Path(cookies_file).exists():
        ydl_opts["cookiefile"] = cookies_file
    if cookies_from_browser:
        ydl_opts["cookiesfrombrowser"] = (cookies_from_browser,)

    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        ret = ydl.download([url])
    if ret != 0:
        raise RuntimeError(f"yt-dlp returned exit code {ret}")
    return _find_video(out_dir)


_MIN_VIDEO_BYTES = 50 * 1024  # anything smaller is almost certainly an error page


def _validate_video(path: str) -> None:
    """Reject a download that isn't a real video so we fall through to the next
    method instead of returning the wrong/empty output (an HTML error page, a
    truncated file, or a stray non-video response)."""
    p = Path(path)
    if not p.exists():
        raise RuntimeError("downloaded file is missing")
    size = p.stat().st_size
    if size < _MIN_VIDEO_BYTES:
        raise RuntimeError(f"downloaded file too small ({size} B) — likely an error page")
    head = p.read_bytes()[:16]
    # mp4/mov carry an 'ftyp' box near the start; webm/mkv start with the EBML magic.
    if b"ftyp" not in head[:12] and not head.startswith(b"\x1aE\xdf\xa3"):
        raise RuntimeError("downloaded file is not a recognized video container")


def _find_video(out_dir: str) -> str:
    for ext in ("mp4", "webm", "mkv", "mov"):
        p = Path(out_dir) / f"video.{ext}"
        if p.exists():
            return str(p)
    raise RuntimeError("Downloaded file not found in temp folder.")


def download_video(
    url: str,
    out_dir: str,
    log: Callable[[str, str], None],
    cookies_file: str | None = None,
    **_ignored,
) -> str:
    errors: list[str] = []
    has_cookies = bool(cookies_file and Path(cookies_file).exists())

    canonical = _resolve_canonical(url, log)
    is_douyin = "douyin" in canonical

    # ── Douyin requires cookies ─────────────────────────────────────────────────
    # Cookies are seeded once via Settings → "Lấy / Cập nhật Cookie" (visible
    # browser, manual login/captcha). No cookie store → stop with a clear message
    # instead of failing deep in the download with a confusing anti-bot error.
    if is_douyin:
        from backend.services.playwright_downloader import load_cookie_header
        if not load_cookie_header():
            raise RuntimeError(
                "Chưa có cookie Douyin. Vào Settings → COOKIE DOUYIN → "
                "'Lấy / Cập nhật Cookie' để lấy cookie trước khi tải.")

    # ── yt-dlp attempts ───────────────────────────────────────────────────────
    # Douyin always rejects cookieless requests ("fresh cookies needed"), so skip
    # that dead attempt and go straight to cookies → Playwright.
    ytdlp_variants: list[tuple[str, str | None, str | None]] = []
    if not is_douyin:
        ytdlp_variants.append(("yt-dlp (no cookies)", None, None))
    if has_cookies:
        ytdlp_variants.append(("yt-dlp (cookies file)", cookies_file, None))
    for browser in _browser_cookie_sources():
        ytdlp_variants.append((f"yt-dlp (browser:{browser})", None, browser))

    for label, cf, browser in ytdlp_variants:
        log(f"Trying {label}...", "info")
        try:
            path = _ytdlp(canonical, out_dir, log, cookies_file=cf, cookies_from_browser=browser)
            _validate_video(path)
            log(f"Downloaded: {Path(path).name}", "success")
            return path
        except Exception as e:
            errors.append(f"{label}: {e}")
            log(f"{label} failed: {e}", "warn")

    # ── Playwright browser intercept (reliable fallback) ─────────────────────
    log("Trying Playwright browser intercept...", "info")
    try:
        from backend.services.playwright_downloader import download_via_playwright
        path = download_via_playwright(canonical, out_dir, log)
        _validate_video(path)
        log(f"Downloaded: {Path(path).name}", "success")
        return path
    except Exception as e:
        errors.append(f"playwright: {e}")
        log(f"Playwright failed: {e}", "warn")

    raise RuntimeError(
        "All download methods failed\n" + "\n".join(f"  - {e}" for e in errors)
    )


if __name__ == "__main__":
    # Offline self-check for the download validator (no network).
    import tempfile

    d = Path(tempfile.mkdtemp())
    too_small = d / "s.mp4"; too_small.write_bytes(b"\x00" * 10)
    not_video = d / "h.mp4"; not_video.write_bytes(b"<html>error</html>" + b"x" * _MIN_VIDEO_BYTES)
    good = d / "v.mp4"; good.write_bytes(b"\x00\x00\x00\x18ftypmp42" + b"\x00" * _MIN_VIDEO_BYTES)

    for bad in (too_small, not_video, d / "missing.mp4"):
        try:
            _validate_video(str(bad)); assert False, f"should reject {bad.name}"
        except RuntimeError:
            pass
    _validate_video(str(good))  # valid mp4 → no raise
    print("OK — downloader validator self-check passed")
