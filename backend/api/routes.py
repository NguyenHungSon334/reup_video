import asyncio
import random
import shutil
import tempfile
import threading
import time
import uuid
from pathlib import Path
from typing import Any
import traceback

from fastapi import APIRouter, HTTPException, WebSocket, WebSocketDisconnect

from ..config import load_config, save_config
from ..services.downloader import download_video
from ..services.gdrive import (
    upload_gdrive,
    _gdrive_service,
    list_folder_files,
    get_file_metadata,
    download_gdrive_file,
    _extract_drive_file_id,
)
from fastapi import UploadFile, File, Form
from ..services.lark import (
    create_lark_records,
    delete_lark_records,
    fetch_lark_data,
    get_field_names,
    update_lark_record_sync,
)
from ..services.processor import process_video

router = APIRouter()

# Per-job log history. A replayable list (not a consume-once Queue) so a client
# that navigates away, reloads, or restarts can reconnect and replay everything
# it missed instead of losing the run.
_job_logs:    dict[str, list[dict[str, Any]]] = {}
_job_events:  dict[str, asyncio.Event] = {}
_job_results: dict[str, dict[str, Any]] = {}
_MAX_STORED_JOBS = 200   # evict oldest results beyond this limit
_MAX_LOGS_PER_JOB = 3000  # ffmpeg progress is chatty; cap so a run can't grow forever

# Lark data cache — avoid hitting Lark API on every page load
_lark_cache: dict = {}
_lark_cache_ts: float = 0.0
_LARK_CACHE_TTL = 300.0  # 5 minutes

# Max concurrent ffmpeg jobs. Default 1 — running >1 encode alongside the
# Flutter GUI causes GPU contention (integrated GPU shared with ffmpeg's
# qsv/amf encoder) that resets the driver and crashes the UI with
# "EGL Error: Context Lost (12302)". Config `max_concurrent_jobs` overrides
# if the machine has a dedicated GPU for encoding (e.g. nvenc on a separate card).
_DEFAULT_CONCURRENCY = 1
_cfg_conc = int(load_config().get("max_concurrent_jobs", 0) or _DEFAULT_CONCURRENCY)
_ffmpeg_semaphore = threading.Semaphore(max(1, _cfg_conc))

# Real-time data-event subscribers
_data_subscribers: set[WebSocket] = set()


def _prune_old_jobs() -> None:
    """Evict oldest job results + their log buffers when over limit."""
    overflow = len(_job_results) - _MAX_STORED_JOBS
    if overflow <= 0:
        return
    to_remove = list(_job_results.keys())[:overflow]
    for k in to_remove:
        _job_results.pop(k, None)
        _job_logs.pop(k, None)
        _job_events.pop(k, None)


def _job_push(job_id: str, msg: dict[str, Any], loop: asyncio.AbstractEventLoop) -> None:
    """Append a log entry and wake any connected websocket readers.

    Called from the worker thread. list.append is atomic under the GIL; the
    Event must be set on the loop thread.
    """
    logs = _job_logs.get(job_id)
    if logs is None:
        return
    if len(logs) >= _MAX_LOGS_PER_JOB and msg.get("type") != "done":
        if len(logs) == _MAX_LOGS_PER_JOB:
            logs.append({"type": "warn", "message": "… log bị cắt bớt (quá dài)"})
        else:
            return
    else:
        logs.append(msg)
    ev = _job_events.get(job_id)
    if ev is not None:
        loop.call_soon_threadsafe(ev.set)


async def _broadcast_data_changed(new_records: list[dict] | None = None) -> None:
    """Notify UI clients that Lark data changed.

    If new_records is provided, patch the in-memory cache and send the new
    rows directly so the UI can prepend them without a full re-fetch.
    Otherwise invalidate the cache so the next GET forces a full reload.
    """
    global _lark_cache_ts, _lark_cache
    if new_records is not None and _lark_cache:
        _lark_cache["records"] = new_records + _lark_cache.get("records", [])
        _lark_cache["total"] = len(_lark_cache["records"])
    else:
        _lark_cache_ts = 0.0
    payload: dict = {"type": "data_changed"}
    if new_records is not None:
        payload["new_records"] = new_records
    dead: set[WebSocket] = set()
    for ws in list(_data_subscribers):
        try:
            await ws.send_json(payload)
        except Exception:
            dead.add(ws)
    _data_subscribers.difference_update(dead)

_AUDIO_EXTS = {".mp3", ".aac", ".wav", ".ogg", ".m4a", ".flac"}


# ── Helpers ───────────────────────────────────────────────────────────────────

def _download_drive_path(path: str, cfg: dict, tmp_dir: str, push) -> str | None:
    file_id = _extract_drive_file_id(path)
    if not file_id:
        return None

    suffix = Path(path).suffix or ""
    if not suffix:
        try:
            meta = get_file_metadata(file_id, credentials_path=cfg.get("gdrive_credentials_path", "").strip() or None)
            suffix = Path(meta.get("name", "")).suffix or ""
        except Exception:
            suffix = ""

    target = Path(tmp_dir) / f"{file_id}{suffix}"
    if target.is_file() and target.stat().st_size > 0:
        push(f"✓ {target.name} already cached", "info")
        return str(target)
    try:
        push(f"▶ Downloading Drive file {file_id}...", "info")
        download_gdrive_file(file_id, str(target), credentials_path=cfg.get("gdrive_credentials_path", "").strip() or None)
        push(f"✓ Downloaded Drive file: {target.name}", "info")
        return str(target)
    except Exception as exc:
        push(f"⚠ Drive download failed: {exc}", "warn")
        return None


_IMAGE_EXTS = {".png", ".webp", ".jpg", ".jpeg"}
_VIDEO_EXTS = {".mp4", ".mov", ".webm", ".mkv", ".avi", ".m4v"}

# Logo/banner are static per config — download once and reuse across every
# video in the run instead of re-fetching from Drive each time (banner is a
# video clip, so re-downloading it per job was the biggest per-video delay).
_ASSET_CACHE_DIR = Path(__file__).resolve().parent.parent / ".cache" / "assets"
_ASSET_CACHE_DIR.mkdir(parents=True, exist_ok=True)
_asset_path_cache: dict[str, str] = {}  # label -> resolved local path, for this process's lifetime


def _pick_image_asset(label: str, folder_key: str, path_key: str,
                      body: dict, cfg: dict, tmp_dir: str, push,
                      exts: set[str] = _IMAGE_EXTS) -> str | None:
    folder_id = cfg.get(folder_key, "").strip()
    path = body.get(path_key, "").strip() or cfg.get(path_key, "").strip()
    cache_key = f"{label}:{folder_id}:{path}"
    cached = _asset_path_cache.get(cache_key)
    if cached and Path(cached).is_file():
        return cached

    # Folder has priority — always pick from Drive folder if configured
    if folder_id:
        try:
            push(f"▶ Fetching {label} from Drive folder {folder_id}...", "info")
            files = list_folder_files(folder_id, credentials_path=cfg.get("gdrive_credentials_path", "").strip() or None)
            imgs = [f for f in files if Path(f.get("name", "")).suffix.lower() in exts]
            if imgs:
                chosen = imgs[0]  # folder has only 1 asset
                push(f"▶ {label}: {chosen['name']}", "info")
                downloaded = _download_drive_path(chosen["id"], cfg, str(_ASSET_CACHE_DIR), push)
                if downloaded:
                    _asset_path_cache[cache_key] = downloaded
                    return downloaded
                push(f"⚠ {label} download failed", "warn")
            else:
                push(f"⚠ No matching files in {label} folder {folder_id}", "warn")
        except Exception as exc:
            push(f"⚠ {label} folder error: {exc}", "warn")

    # Fallback: direct path (local file or Drive URL)
    if not path:
        push(f"⚠ {label} không được cấu hình ({folder_key} hoặc {path_key} cần được đặt)", "warn")
        return None

    file_path = Path(path)
    if file_path.is_file():
        _asset_path_cache[cache_key] = str(file_path)
        return str(file_path)

    downloaded = _download_drive_path(path, cfg, str(_ASSET_CACHE_DIR), push)
    if downloaded:
        _asset_path_cache[cache_key] = downloaded
        return downloaded

    push(f"⚠ {label} path không hợp lệ: {path}", "warn")
    return None


def _pick_logo(body: dict, cfg: dict, tmp_dir: str, push) -> str | None:
    return _pick_image_asset("Logo", "logo_gdrive_folder_id", "logo_path", body, cfg, tmp_dir, push)


def _pick_banner(body: dict, cfg: dict, tmp_dir: str, push) -> str | None:
    # Banner is a video clip overlaid on the reup video.
    return _pick_image_asset("Banner", "banner_gdrive_folder_id", "banner_path",
                             body, cfg, tmp_dir, push, exts=_VIDEO_EXTS)


def _pick_music(body: dict, cfg: dict, tmp_dir: str, push) -> tuple[str | None, str | None]:
    """Returns (file_path, file_name). Picks random track from configured folder."""
    # Priority 1: Drive folder (random pick)
    remote_folder_id = cfg.get("music_gdrive_folder_id", "").strip()
    if remote_folder_id:
        try:
            push(f"▶ Fetching music list from Drive folder {remote_folder_id}...", "info")
            files = list_folder_files(remote_folder_id, credentials_path=cfg.get("gdrive_credentials_path", "").strip() or None)
            music_files = [f for f in files if Path(f.get("name", "")).suffix.lower() in _AUDIO_EXTS]
            if music_files:
                chosen = random.choice(music_files)
                push(f"♪ Music: {chosen['name']}", "info")
                downloaded = _download_drive_path(chosen["id"], cfg, tmp_dir, push)
                if downloaded:
                    return downloaded, chosen["name"]
                push("⚠ Music download failed", "warn")
            else:
                push(f"⚠ No audio files in music folder {remote_folder_id}", "warn")
        except Exception as exc:
            push(f"⚠ Drive music folder error: {exc}", "warn")

    # Priority 2: Local folder
    folder = cfg.get("music_folder", "").strip()
    if folder:
        p = Path(folder)
        if p.is_dir():
            files = [f for f in p.iterdir() if f.suffix.lower() in _AUDIO_EXTS]
            if files:
                chosen = random.choice(files)
                push(f"♪ Music: {chosen.name}", "info")
                return str(chosen), chosen.name
            push("⚠ Local music folder has no audio files", "warn")

    # Priority 3: Direct path
    path = body.get("music_path", "").strip() or cfg.get("music_path", "").strip()
    if path:
        file_path = Path(path)
        if file_path.is_file():
            return str(file_path), file_path.name
        downloaded = _download_drive_path(path, cfg, tmp_dir, push)
        if downloaded:
            return downloaded, Path(downloaded).name

    push("⚠ Nhạc không được cấu hình (music_gdrive_folder_id cần được đặt)", "warn")
    return None, None


# ── Routes ────────────────────────────────────────────────────────────────────

@router.get("/health")
async def health():
    return {"status": "ok"}


@router.get("/config")
async def get_config():
    return load_config()


@router.post("/config")
async def set_config(body: dict):
    save_config(body)
    return {"ok": True}


@router.get("/media/dims")
async def media_dims(path: str):
    """Probe a local video/image file's actual pixel width/height (for the
    banner scale preview in Settings — needs the real source dims, not a
    guess)."""
    from backend.services.processor import probe_dims
    if not _os.path.isfile(path):
        return {"ok": False, "error": "File không tồn tại trên máy này."}
    dims = probe_dims(path)
    if not dims:
        return {"ok": False, "error": "Không đọc được kích thước file."}
    return {"ok": True, "width": dims[0], "height": dims[1]}


@router.get("/gdrive/status")
async def gdrive_status():
    """Service account auth — no token, no browser. Just verify the service builds."""
    if not GDRIVE_OK_CHECK():
        return {"connected": False, "reason": "Google Drive libraries not installed."}
    cfg              = load_config()
    credentials_path = cfg.get("gdrive_credentials_path", "").strip() or None
    try:
        loop = asyncio.get_running_loop()
        await loop.run_in_executor(None, lambda: _gdrive_service(credentials_path))
        return {"connected": True}
    except Exception as exc:
        return {"connected": False, "reason": str(exc)}


@router.post("/gdrive/connect")
async def gdrive_connect():
    """Trigger OAuth flow — opens browser on the server machine."""
    cfg              = load_config()
    credentials_path = cfg.get("gdrive_credentials_path", "").strip() or None
    loop             = asyncio.get_running_loop()
    try:
        await loop.run_in_executor(None, lambda: _gdrive_service(credentials_path))
        return {"connected": True}
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@router.get("/gdrive/list")
async def gdrive_list(folder_id: str | None = None):
    """List files in a Drive folder. If folder_id omitted, use config `music_gdrive_folder_id` or `gdrive_folder_id`."""
    cfg = load_config()
    fid = (folder_id or cfg.get("music_gdrive_folder_id") or cfg.get("gdrive_folder_id") or "").strip()
    if not fid:
        raise HTTPException(status_code=400, detail="No folder_id provided and no default configured.")
    try:
        files = list_folder_files(fid, credentials_path=cfg.get("gdrive_credentials_path", "") or None)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {"files": files}


@router.post("/gdrive/upload")
async def gdrive_upload(file: UploadFile = File(...), folder_id: str | None = Form(None)):
    """Upload an incoming file to the specified Drive folder (or default from config). Returns file metadata and logs."""
    cfg = load_config()
    target = (folder_id or cfg.get("music_gdrive_folder_id") or cfg.get("gdrive_folder_id") or "").strip()
    if not target:
        raise HTTPException(status_code=400, detail="No target folder_id provided or configured.")

    tmp = None
    logs: list[dict] = []

    def push_log(msg: str, t: str = "info") -> None:
        logs.append({"type": t, "message": msg})

    try:
        suffix = Path(file.filename).suffix or ""
        with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tf:
            tmp = tf.name
            content = await file.read()
            tf.write(content)

        link = upload_gdrive(tmp, target, push_log, credentials_path=cfg.get("gdrive_credentials_path", "") or None)
        file_id = _extract_drive_file_id(link) or None
        meta = get_file_metadata(file_id, credentials_path=cfg.get("gdrive_credentials_path", "") or None) if file_id else {"webViewLink": link}
        return {"ok": True, "link": link, "logs": logs, "meta": meta}
    except Exception as exc:
        return {"ok": False, "error": str(exc), "logs": logs}
    finally:
        try:
            if tmp:
                Path(tmp).unlink(missing_ok=True)
        except Exception:
            pass


def GDRIVE_OK_CHECK() -> bool:
    try:
        import google.auth  # noqa: F401
        return True
    except ImportError:
        return False


@router.get("/cookies/status")
async def cookies_status():
    """Whether the Douyin cookie JSON store exists, and how many cookies it has."""
    import json as _json
    from ..config import COOKIES_JSON_FILE
    if not COOKIES_JSON_FILE.exists() or COOKIES_JSON_FILE.stat().st_size == 0:
        return {"has_cookies": False}
    try:
        cookies = _json.loads(COOKIES_JSON_FILE.read_text(encoding="utf-8"))
        return {"has_cookies": bool(cookies), "count": len(cookies),
                "updated": int(COOKIES_JSON_FILE.stat().st_mtime)}
    except Exception as exc:
        return {"has_cookies": False, "reason": str(exc)}


def _parse_cookies_text(text: str) -> list[dict]:
    """Parse pasted cookies into the JSON list store format [{name,value}, ...].
    Accepts: a JSON array of cookie objects (browser-extension export), a JSON
    object {name: value}, or a raw header string 'a=b; c=d'."""
    import json as _json
    text = (text or "").strip()
    if not text:
        return []
    # JSON array or object
    if text[0] in "[{":
        try:
            data = _json.loads(text)
        except Exception:
            data = None
        if isinstance(data, list):
            out = []
            for c in data:
                if isinstance(c, dict) and c.get("name") and "value" in c:
                    out.append({"name": str(c["name"]), "value": str(c["value"])})
            if out:
                return out
        elif isinstance(data, dict):
            return [{"name": str(k), "value": str(v)} for k, v in data.items() if k]
    # header string: a=b; c=d
    out = []
    for part in text.replace("\n", ";").split(";"):
        part = part.strip()
        if not part or "=" not in part:
            continue
        name, _, value = part.partition("=")
        name = name.strip()
        if name:
            out.append({"name": name, "value": value.strip()})
    return out


# Cookies Douyin depends on for auth / anti-bot; report which are present.
_KEY_COOKIES = ("sessionid", "sessionid_ss", "ttwid", "passport_csrf_token")


def _to_netscape(cookies: list[dict]) -> str:
    """Render cookies as a Netscape cookies.txt — the format yt-dlp's
    `cookiefile` expects. All cookies scoped to .douyin.com (subdomains on)."""
    # ponytail: fixed 1-year expiry; Douyin session cookies outlive one download.
    expiry = int(time.time()) + 365 * 24 * 3600
    lines = ["# Netscape HTTP Cookie File"]
    for c in cookies:
        name = c["name"]
        value = c["value"]
        lines.append(
            f".douyin.com\tTRUE\t/\tFALSE\t{expiry}\t{name}\t{value}")
    return "\n".join(lines) + "\n"


@router.get("/cookies/raw")
async def cookies_raw():
    """Saved cookies as a 'name=value; ...' header string, so the Settings box can
    show what was previously entered instead of starting empty each time."""
    from ..services.playwright_downloader import load_cookie_header
    return {"cookie": load_cookie_header()}


@router.post("/cookies/set")
async def cookies_set(payload: dict):
    """Save cookies pasted by the user and report which key cookies are present.
    Writes BOTH stores: the JSON store (Playwright/httpx header path) and the
    Netscape cookies.txt that yt-dlp reads via cookiefile.
    ponytail: presence check, not a live Douyin request — that path is fragile."""
    import json as _json
    from ..config import COOKIES_JSON_FILE, COOKIES_STORE_FILE, save_config
    cookies = _parse_cookies_text(payload.get("text", ""))
    if not cookies:
        return {"ok": False, "error": "Không đọc được cookie nào từ nội dung dán."}
    names = {c["name"] for c in cookies}
    present = [k for k in _KEY_COOKIES if k in names]
    try:
        COOKIES_JSON_FILE.parent.mkdir(parents=True, exist_ok=True)
        COOKIES_JSON_FILE.write_text(_json.dumps(cookies), encoding="utf-8")
        # yt-dlp cookiefile: write Netscape store + point config at it.
        save_config({"cookies_text": _to_netscape(cookies)})
    except Exception as exc:
        return {"ok": False, "error": f"Lưu cookie thất bại: {exc}"}
    return {"ok": True, "count": len(cookies), "key_cookies": present,
            "warn": None if present else
            "Thiếu cookie đăng nhập (sessionid/ttwid) — có thể tải sẽ lỗi."}


@router.post("/cookies/refresh")
async def cookies_refresh():
    """Open a real browser window to seed/refresh the Douyin cookie JSON. Solve any
    captcha / scan QR in the window; cookies save when it finishes."""
    logs: list[dict] = []

    def push(msg: str, t: str = "info") -> None:
        logs.append({"type": t, "message": msg})

    loop = asyncio.get_running_loop()
    try:
        from ..services.playwright_downloader import seed_cookies, load_cookie_header
        await loop.run_in_executor(None, lambda: seed_cookies(push))
        return {"ok": bool(load_cookie_header()), "logs": logs}
    except Exception as exc:
        return {"ok": False, "error": str(exc), "logs": logs}


@router.get("/lark/fields")
async def get_lark_fields():
    """Return the field names in the Lark table — use this to configure field mapping."""
    cfg        = load_config()
    app_id     = cfg.get("lark_app_id", "").strip()
    app_secret = cfg.get("lark_app_secret", "").strip()
    if not app_id or not app_secret:
        raise HTTPException(status_code=400, detail="Lark credentials not configured.")
    try:
        fields = await get_field_names(app_id, app_secret)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {"fields": fields}


@router.get("/lark/kenh-options")
async def get_kenh_options():
    """Return the single-select options for the Kênh field."""
    from ..services.lark import get_field_options
    cfg        = load_config()
    app_id     = cfg.get("lark_app_id", "").strip()
    app_secret = cfg.get("lark_app_secret", "").strip()
    if not app_id or not app_secret:
        raise HTTPException(status_code=400, detail="Lark credentials not configured.")
    field_name = cfg.get("lark_field_kenh", "Kênh")
    try:
        options = await get_field_options(app_id, app_secret, field_name)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {"options": options}


def _lark_field_map(cfg: dict) -> dict:
    return {
        "link":       cfg.get("lark_field_link",       "Link"),
        "link_completed": cfg.get("lark_field_link_completed", "Link completed"),
        "music":      cfg.get("lark_field_music",      "Nhạc"),
        "music_name": cfg.get("lark_field_music_name", "Tên nhạc"),
        "status":     cfg.get("lark_field_status",     "Status"),
        "kenh":       cfg.get("lark_field_kenh",       "Kênh"),
    }


@router.post("/records/submit")
async def submit_records(body: dict):
    """Create Lark records from a list of {url, use_music} items."""
    cfg = load_config()
    app_id     = cfg.get("lark_app_id", "").strip()
    app_secret = cfg.get("lark_app_secret", "").strip()
    if not app_id or not app_secret:
        raise HTTPException(
            status_code=400,
            detail="Lark credentials not configured. Go to Settings page.",
        )
    items = body.get("items", [])
    if not items:
        raise HTTPException(status_code=400, detail="No items provided")
    fm = _lark_field_map(cfg)
    try:
        record_ids = await create_lark_records(
            app_id, app_secret, items, field_map=fm
        )
    except Exception as exc:
        # Print full traceback to server console for debugging
        tb = traceback.format_exc()
        print("[ERROR] /records/submit exception:\n", tb)
        raise HTTPException(status_code=502, detail=str(exc)) from exc

    # Build minimal record dicts so the UI can prepend without a full re-fetch
    fields_list: list[str] = (_lark_cache.get("fields") or []) if _lark_cache else []
    new_records: list[dict] = []
    for rid, item in zip(record_ids, items):
        row: dict = {f: "" for f in fields_list}
        row[fm["link"]] = item.get("url", "")
        row[fm["music"]] = "yes" if item.get("use_music") else "no"
        row[fm["status"]] = "Chờ xử lý"
        if item.get("kenh"):
            row[fm["kenh"]] = item["kenh"]
        row["_record_id"] = rid
        new_records.append(row)

    await _broadcast_data_changed(new_records=new_records)
    return {"record_ids": record_ids, "count": len(record_ids)}


@router.post("/jobs")
async def start_job(body: dict):
    job_id = str(uuid.uuid4())
    loop   = asyncio.get_running_loop()
    _job_logs[job_id]   = []
    _job_events[job_id] = asyncio.Event()

    def push(message: str, log_type: str = "info") -> None:
        _job_push(job_id, {"type": log_type, "message": message}, loop)

    def worker() -> None:
        tmp    = tempfile.mkdtemp(prefix="reup_")
        result: dict[str, Any] = {}
        cfg    = load_config()

        app_id     = cfg.get("lark_app_id", "").strip()
        app_secret = cfg.get("lark_app_secret", "").strip()
        record_id  = body.get("record_id", "").strip()

        fm = _lark_field_map(cfg)

        def lark_update(logical_fields: dict) -> None:
            if not (record_id and app_id and app_secret):
                return
            mapped = {fm.get(k, k): v for k, v in logical_fields.items()}
            err = update_lark_record_sync(app_id, app_secret, record_id, mapped)
            if err:
                push(f"⚠ Lark: {err}", "warn")

        try:
            push(f"▶ Job {job_id[:8]}... started")
            lark_update({"status": "Đang tải..."})

            video = download_video(
                body["url"], tmp, push,
                cookies_browser=cfg.get("cookies_browser", "").strip() or None,
                cookies_file=cfg.get("cookies_file", "").strip() or None,
            )

            use_logo   = body.get("use_logo", False)
            use_music  = body.get("use_music", False)
            use_banner = body.get("use_banner", cfg.get("use_banner", False))
            logo      = _pick_logo(body, cfg, tmp, push) if use_logo else None
            banner    = _pick_banner(body, cfg, tmp, push) if use_banner else None
            music, music_name = _pick_music(body, cfg, tmp, push) if use_music else (None, None)

            if music_name:
                lark_update({"music_name": music_name})

            lark_update({"status": "Đang xử lý..."})

            if use_logo or use_music or use_banner:
                out = str(Path(tmp) / "output.mp4")
                logo_scale    = int(cfg.get("logo_scale", 150))
                logo_position = cfg.get("logo_position", "top_left")
                logo_opacity  = float(cfg.get("logo_opacity", 1.0))
                max_height    = int(cfg.get("max_height", 720))
                banner_scale_pct = float(cfg.get("banner_scale_pct", 100.0))
                push("⏳ Chờ slot xử lý...", "info")
                with _ffmpeg_semaphore:
                    process_video(video, out, push, logo=logo, music=music, banner=banner,
                                  logo_scale=logo_scale, logo_position=logo_position,
                                  logo_opacity=logo_opacity, max_height=max_height,
                                  banner_scale_pct=banner_scale_pct)
            else:
                out = video
                push("⊘ No processing (logo + banner + music all off)", "info")

            mode = body.get("save_to", "drive")
            if mode == "local":
                dest_dir = body.get("local_folder", "").strip()
                if not dest_dir:
                    raise ValueError("local_folder is required for local save")
                final = str(Path(dest_dir) / Path(video).name)
                shutil.copy2(out, final)
                push(f"✓ Saved: {final}", "success")
                result = {"status": "success", "path": final}
            else:
                _DEFAULT_FOLDER = cfg.get("reup_gdrive_folder_id") or cfg.get("gdrive_folder_id") or "1Oi3Rx1_nMfOIMh-L8iiJ1Z2d34YKJMxy"
                folder_id = (
                    body.get("reup_gdrive_folder_id")
                    or body.get("gdrive_folder_id")
                    or cfg.get("reup_gdrive_folder_id")
                    or cfg.get("gdrive_folder_id")
                    or _DEFAULT_FOLDER
                ).strip()
                if not folder_id:
                    raise ValueError("No Google Drive folder configured for upload")
                credentials_path = cfg.get("gdrive_credentials_path", "").strip() or None
                push(f"📁 Drive folder ID: {folder_id}", "info")
                link = upload_gdrive(out, folder_id, push, credentials_path=credentials_path)
                push(f"▶ Updating Lark field '{fm.get('link_completed')}' with Drive link...", "info")
                lark_update({"link_completed": link})
                result = {"status": "success", "link": link}

            lark_update({"status": "Hoàn thành ✓"})

        except Exception as exc:
            push(f"✗ ERROR: {exc}", "error")
            lark_update({"status": f"Lỗi: {exc}"})
            result = {"status": "error", "message": str(exc)}
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

        _job_results[job_id] = result
        _prune_old_jobs()
        asyncio.run_coroutine_threadsafe(_broadcast_data_changed(), loop)
        _job_push(job_id, {"type": "done", "result": result}, loop)

        # Keep the log buffer around after the job finishes so a client that was
        # closed/navigated away can still reconnect and replay the whole run.
        def _deferred_log_cleanup() -> None:
            time.sleep(600)
            _job_logs.pop(job_id, None)
            _job_events.pop(job_id, None)

        threading.Thread(target=_deferred_log_cleanup, daemon=True).start()

    threading.Thread(target=worker, daemon=True).start()
    return {"job_id": job_id}


@router.get("/jobs/{job_id}")
async def get_job_status(job_id: str):
    result = _job_results.get(job_id)
    if result is None:
        return {"status": "running"}
    return result


@router.get("/lark/data")
async def get_lark_data(refresh: bool = False, page: int = 1, page_size: int = 0):
    """Return Lark records. page_size=0 returns all (default). page_size>0 paginates."""
    global _lark_cache, _lark_cache_ts
    cfg        = load_config()
    app_id     = cfg.get("lark_app_id", "").strip()
    app_secret = cfg.get("lark_app_secret", "").strip()
    if not app_id or not app_secret:
        raise HTTPException(
            status_code=400,
            detail="Lark credentials not configured. Go to Settings page.",
        )

    now = time.monotonic()
    if not refresh and _lark_cache and (now - _lark_cache_ts) < _LARK_CACHE_TTL:
        data = _lark_cache
    else:
        try:
            data = await asyncio.wait_for(
                fetch_lark_data(app_id, app_secret),
                timeout=75.0,
            )
        except asyncio.TimeoutError:
            if _lark_cache:
                data = _lark_cache  # stale cache on timeout
            else:
                raise HTTPException(status_code=504, detail="Lark API timeout — quá 75 giây, thử lại.")
        except Exception as exc:
            if _lark_cache:
                data = _lark_cache  # stale cache on error
            else:
                raise HTTPException(status_code=502, detail=str(exc)) from exc
        else:
            _lark_cache = data
            _lark_cache_ts = now

    if page_size <= 0:
        return data

    all_records = data["records"]
    total = len(all_records)
    page = max(1, page)
    start = (page - 1) * page_size
    sliced = all_records[start: start + page_size]
    total_pages = (total + page_size - 1) // page_size
    return {
        "fields": data["fields"],
        "records": sliced,
        "total": total,
        "page": page,
        "page_size": page_size,
        "total_pages": total_pages,
        "has_more": page < total_pages,
    }


@router.post("/records/delete")
async def delete_records(body: dict):
    record_ids = body.get("record_ids", [])
    if not record_ids:
        raise HTTPException(status_code=400, detail="record_ids is required")
    cfg        = load_config()
    app_id     = cfg.get("lark_app_id", "").strip()
    app_secret = cfg.get("lark_app_secret", "").strip()
    if not app_id or not app_secret:
        raise HTTPException(status_code=400, detail="Lark credentials not configured.")
    try:
        count = await delete_lark_records(app_id, app_secret, record_ids)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    await _broadcast_data_changed()
    return {"deleted": count}


@router.websocket("/ws/data-events")
async def ws_data_events(websocket: WebSocket):
    await websocket.accept()
    _data_subscribers.add(websocket)
    try:
        while True:
            try:
                await asyncio.wait_for(websocket.receive_text(), timeout=30.0)
            except asyncio.TimeoutError:
                await websocket.send_json({"type": "ping"})
    except WebSocketDisconnect:
        pass
    finally:
        _data_subscribers.discard(websocket)


@router.websocket("/ws/{job_id}")
async def ws_logs(websocket: WebSocket, job_id: str):
    await websocket.accept()
    logs = _job_logs.get(job_id)
    if logs is None:
        # Buffer already cleaned up. If the result survived, hand it straight
        # back so a reconnecting client can still settle the row.
        result = _job_results.get(job_id)
        if result is not None:
            await websocket.send_json({"type": "done", "result": result})
        else:
            await websocket.send_json({"type": "error", "message": "Job not found"})
        await websocket.close()
        return

    ev = _job_events.setdefault(job_id, asyncio.Event())
    cursor = 0        # this client's own position — replays history from 0
    total_waited = 0
    try:
        while True:
            # Drain everything appended since we last looked.
            while cursor < len(logs):
                msg = logs[cursor]
                cursor += 1
                await websocket.send_json(msg)
                if msg.get("type") == "done":
                    return
            ev.clear()
            if cursor < len(logs):
                continue  # appended between the drain and the clear
            try:
                # ponytail: one shared Event for all readers of a job — a
                # concurrent reader's clear() can swallow a wake-up, but the
                # 25s timeout re-drains anyway. Per-reader events if that lag
                # ever matters.
                await asyncio.wait_for(ev.wait(), timeout=25.0)
                total_waited = 0
            except asyncio.TimeoutError:
                total_waited += 25
                if total_waited >= 600:
                    await websocket.send_json({"type": "error", "message": "Job timed out"})
                    return
                # Keepalive ping — prevents Railway proxy from closing idle WS
                await websocket.send_json({"type": "ping"})
    except WebSocketDisconnect:
        pass
    # Buffer is intentionally NOT dropped here — the client may reconnect.
