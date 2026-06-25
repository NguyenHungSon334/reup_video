import re
import subprocess
import sys
from pathlib import Path
from typing import Callable

import httpx

_NO_WINDOW = subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0

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


def _ytdlp(url: str, out_dir: str, log: Callable, cookies_file: str | None = None) -> str:
    tpl = str(Path(out_dir) / "video.%(ext)s")
    cmd = [
        sys.executable, "-m", "yt_dlp",
        "--no-playlist", "-o", tpl,
        "--merge-output-format", "mp4",
        "--add-header", "Referer:https://www.douyin.com",
        "--add-header", f"User-Agent:{_MOBILE_UA}",
    ]
    if cookies_file and Path(cookies_file).exists():
        cmd += ["--cookies", cookies_file]
    cmd.append(url)

    output_lines: list[str] = []
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, encoding="utf-8", errors="replace",
        creationflags=_NO_WINDOW,
    )
    for line in proc.stdout:
        line = line.rstrip()
        if line:
            output_lines.append(line)
            log(line, "info")
    proc.wait()
    if proc.returncode != 0:
        last = next((l for l in reversed(output_lines) if l.strip()), "no output")
        raise RuntimeError(f"yt-dlp: {last}")
    return _find_video(out_dir)


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
    cookies_browser: str | None = None,
    cookies_file: str | None = None,
) -> str:
    errors: list[str] = []
    has_cookies = bool(cookies_file and Path(cookies_file).exists())

    canonical = _resolve_canonical(url, log)

    # ── yt-dlp (fast, works if cookies are fresh) ────────────────────────────
    for label, cf in [
        ("yt-dlp (no cookies)", None),
        ("yt-dlp (cookies file)", cookies_file if has_cookies else None),
    ]:
        if cf is None and label != "yt-dlp (no cookies)":
            continue
        log(f"Trying {label}...", "info")
        try:
            path = _ytdlp(canonical, out_dir, log, cookies_file=cf)
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
        log(f"Downloaded: {Path(path).name}", "success")
        return path
    except Exception as e:
        errors.append(f"playwright: {e}")
        log(f"Playwright failed: {e}", "warn")

    raise RuntimeError(
        "All download methods failed\n" + "\n".join(f"  - {e}" for e in errors)
    )
