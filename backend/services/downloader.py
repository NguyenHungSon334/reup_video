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
_DESKTOP_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
)
_HEADERS = {
    "User-Agent": _MOBILE_UA,
    "Referer":    "https://www.douyin.com/",
}


def _normalize_url(url: str) -> str:
    """Extract video ID from URL and return canonical douyin.com/video/ID."""
    m = re.search(r'/(?:share/)?video/(\d{15,20})', url)
    if m:
        return f"https://www.douyin.com/video/{m.group(1)}"
    return url


def _resolve_canonical(url: str, log: Callable) -> str:
    """
    Resolve any Douyin URL to canonical douyin.com/video/ID.
    Handles: v.douyin.com short URLs, iesdouyin.com share URLs, direct URLs.
    """
    # Try direct extraction first (iesdouyin.com/share/video/ID, douyin.com/video/ID)
    canonical = _normalize_url(url)
    if canonical != url:
        log(f"  Canonical: {canonical}", "info")
        return canonical

    # Short URL — must resolve redirect
    log(f"  Resolving short URL...", "info")
    try:
        with httpx.Client(headers=_HEADERS, follow_redirects=True, timeout=15) as c:
            resp     = c.get(url)
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

    return url  # fallback


# ── yt-dlp ────────────────────────────────────────────────────────────────────

def _ytdlp(
    url: str,
    out_dir: str,
    log: Callable,
    cookies_browser: str | None,
    cookies_file: str | None,
) -> str:
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
    elif cookies_browser:
        cmd += ["--cookies-from-browser", cookies_browser]
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


# ── gallery-dl ────────────────────────────────────────────────────────────────

def _gallery_dl(url: str, out_dir: str, log: Callable) -> str:
    try:
        import gallery_dl  # noqa: F401 — just check it's installed
    except ImportError:
        raise RuntimeError("gallery-dl not installed. Run: pip install gallery-dl")

    cmd = [
        sys.executable, "-m", "gallery_dl",
        "--destination", out_dir,
        "--filename", "video.%(extension)s",
        url,
    ]
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
        raise RuntimeError(f"gallery-dl: {last}")
    return _find_video(out_dir)


# ── Direct Douyin HTTP ────────────────────────────────────────────────────────

def _douyin_direct(url: str, out_dir: str, log: Callable) -> str:
    """
    Fallback: extract video ID from URL → scrape douyin.com/video/ID page
    → parse __NEXT_DATA__ JSON for play URL → stream download.
    """
    import json as _json

    # Step 1 — get video ID (from iesdouyin share URL or short URL redirect)
    vid_id = _extract_video_id(url)
    if not vid_id:
        headers_resolve = {**_HEADERS, "User-Agent": _DESKTOP_UA}
        with httpx.Client(headers=headers_resolve, follow_redirects=True, timeout=20) as c:
            resp  = c.get(url)
            long  = str(resp.url)
            log(f"  Resolved: {long[:90]}", "info")
            vid_id = _extract_video_id(long)
    if not vid_id:
        raise RuntimeError("Cannot extract video ID from URL")
    log(f"  Video ID: {vid_id}", "info")

    page_url = f"https://www.douyin.com/video/{vid_id}"
    page_headers = {
        "User-Agent": _DESKTOP_UA,
        "Referer":    "https://www.douyin.com/",
        "Accept-Language": "zh-CN,zh;q=0.9",
    }

    with httpx.Client(headers=page_headers, follow_redirects=True, timeout=30) as client:
        # Step 2 — fetch video page
        r    = client.get(page_url)
        html = r.text

        # Step 3 — extract __NEXT_DATA__ or RENDER_DATA
        dl_url: str | None = None

        # Try __NEXT_DATA__ (Next.js)
        m = re.search(r'<script id="__NEXT_DATA__"[^>]*>(.*?)</script>', html, re.DOTALL)
        if m:
            try:
                nd   = _json.loads(m.group(1))
                dl_url = _pick_url_from_next_data(nd)
            except Exception:
                pass

        # Try RENDER_DATA (older Douyin page format)
        if not dl_url:
            m2 = re.search(r'window\._ROUTER_DATA\s*=\s*(\{.*?\});\s*</script>', html, re.DOTALL)
            if m2:
                try:
                    rd = _json.loads(m2.group(1))
                    dl_url = _pick_url_from_render_data(rd, vid_id)
                except Exception:
                    pass

        if not dl_url:
            raise RuntimeError("Cannot find video URL in Douyin page HTML")

        log(f"  Downloading via page scrape...", "info")

        # Step 4 — stream download
        out_path = str(Path(out_dir) / "video.mp4")
        with client.stream("GET", dl_url, timeout=120) as stream:
            stream.raise_for_status()
            total      = int(stream.headers.get("content-length", 0))
            downloaded = 0
            with open(out_path, "wb") as f:
                for chunk in stream.iter_bytes(chunk_size=1024 * 1024):
                    f.write(chunk)
                    downloaded += len(chunk)
                    if total:
                        log(f"  {int(downloaded / total * 100)}%", "info")

    return out_path


def _pick_url_from_next_data(nd: dict) -> str | None:
    """Walk Next.js page props to find a play URL."""
    try:
        # Common path: props → pageProps → videoInfo → video → playApi
        props = nd.get("props", {}).get("pageProps", {})
        video_info = (
            props.get("videoInfo")
            or props.get("awemeDetail")
            or props.get("itemInfo", {}).get("itemStruct")
        )
        if video_info:
            return _extract_play_url(video_info.get("video", {}))
    except Exception:
        pass
    return None


def _pick_url_from_render_data(rd: dict, vid_id: str) -> str | None:
    """Walk ROUTER_DATA to find play URL for given video ID."""
    try:
        # loaders key contains detail page data
        for key, val in rd.items():
            if not isinstance(val, dict):
                continue
            aweme = val.get("awemeDetail") or val.get("videoInfo")
            if aweme and str(aweme.get("awemeId", "")) == vid_id:
                return _extract_play_url(aweme.get("video", {}))
    except Exception:
        pass
    return None


def _extract_play_url(video: dict) -> str | None:
    """Pull best play URL from a Douyin video dict."""
    for key in ("playApi", "playAddr", "play_addr", "download_addr"):
        obj = video.get(key)
        if not obj:
            continue
        urls = obj if isinstance(obj, list) else obj.get("urlList") or obj.get("url_list") or []
        if urls:
            best = next((u for u in urls if "playwm" not in u), urls[0])
            return best.replace("playwm", "play")
    return None


def _extract_video_id(url: str) -> str | None:
    for pattern in (
        r"/video/(\d+)",
        r"aweme_id=(\d+)",
        r"/(\d{15,19})",
    ):
        m = re.search(pattern, url)
        if m:
            return m.group(1)
    return None


# ── File finder ───────────────────────────────────────────────────────────────

def _find_video(out_dir: str) -> str:
    for ext in ("mp4", "webm", "mkv", "mov"):
        p = Path(out_dir) / f"video.{ext}"
        if p.exists():
            return str(p)
    raise RuntimeError("Downloaded file not found in temp folder.")


# ── Public entry point ────────────────────────────────────────────────────────

def download_video(
    url: str,
    out_dir: str,
    log: Callable[[str, str], None],
    cookies_browser: str | None = None,
    cookies_file: str | None = None,
) -> str:
    errors: list[str] = []

    # Resolve to canonical douyin.com/video/ID before any method
    canonical = _resolve_canonical(url, log)

    # 1 — yt-dlp
    log("▶ Trying yt-dlp...", "info")
    try:
        path = _ytdlp(canonical, out_dir, log, cookies_browser, cookies_file)
        log(f"✓ Downloaded: {Path(path).name}", "success")
        return path
    except Exception as e:
        errors.append(f"yt-dlp: {e}")
        log(f"⚠ yt-dlp failed: {e}", "warn")

    # 2 — gallery-dl
    log("▶ Trying gallery-dl...", "info")
    try:
        path = _gallery_dl(canonical, out_dir, log)
        log(f"✓ Downloaded: {Path(path).name}", "success")
        return path
    except Exception as e:
        errors.append(f"gallery-dl: {e}")
        log(f"⚠ gallery-dl failed: {e}", "warn")

    # 3 — direct Douyin HTTP
    log("▶ Trying direct Douyin API...", "info")
    try:
        path = _douyin_direct(canonical, out_dir, log)
        log(f"✓ Downloaded: {Path(path).name}", "success")
        return path
    except Exception as e:
        errors.append(f"direct API: {e}")
        log(f"⚠ Direct API failed: {e}", "warn")

    raise RuntimeError(
        "All download methods failed:\n" + "\n".join(f"  • {e}" for e in errors)
    )
