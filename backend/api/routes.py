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
    TOKEN_FILE,
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

_job_queues:  dict[str, asyncio.Queue] = {}
_job_results: dict[str, dict[str, Any]] = {}

# Lark data cache — avoid hitting Lark API on every page load
_lark_cache: dict = {}
_lark_cache_ts: float = 0.0
_LARK_CACHE_TTL = 300.0  # 5 minutes

# Max concurrent ffmpeg jobs — 1 at a time keeps peak RAM under 512 MB
_ffmpeg_semaphore = threading.Semaphore(1)

# Real-time data-event subscribers
_data_subscribers: set[WebSocket] = set()


async def _broadcast_data_changed() -> None:
    """Invalidate cache and notify all UI clients that Lark data changed."""
    global _lark_cache_ts
    _lark_cache_ts = 0.0
    dead: set[WebSocket] = set()
    for ws in list(_data_subscribers):
        try:
            await ws.send_json({"type": "data_changed"})
        except Exception:
            dead.add(ws)
    _data_subscribers -= dead

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
    try:
        push(f"▶ Downloading Drive file {file_id}...", "info")
        download_gdrive_file(file_id, str(target), credentials_path=cfg.get("gdrive_credentials_path", "").strip() or None)
        push(f"✓ Downloaded Drive file: {target.name}", "info")
        return str(target)
    except Exception as exc:
        push(f"⚠ Drive download failed: {exc}", "warn")
        return None


def _pick_logo(body: dict, cfg: dict, tmp_dir: str, push) -> str | None:
    # Folder has priority — always pick from Drive folder if configured
    folder_id = cfg.get("logo_gdrive_folder_id", "").strip()
    if folder_id:
        try:
            push(f"▶ Fetching logo from Drive folder {folder_id}...", "info")
            files = list_folder_files(folder_id, credentials_path=cfg.get("gdrive_credentials_path", "").strip() or None)
            logos = [f for f in files if Path(f.get("name", "")).suffix.lower() in {".png", ".webp", ".jpg", ".jpeg"}]
            if logos:
                chosen = logos[0]  # folder has only 1 logo
                push(f"▶ Logo: {chosen['name']}", "info")
                downloaded = _download_drive_path(chosen["id"], cfg, tmp_dir, push)
                if downloaded:
                    return downloaded
                push("⚠ Logo download failed", "warn")
            else:
                push(f"⚠ No image files in logo folder {folder_id}", "warn")
        except Exception as exc:
            push(f"⚠ Logo folder error: {exc}", "warn")

    # Fallback: direct path (local file or Drive URL)
    path = body.get("logo_path", "").strip() or cfg.get("logo_path", "").strip()
    if not path:
        push("⚠ Logo không được cấu hình (logo_gdrive_folder_id hoặc logo_path cần được đặt)", "warn")
        return None

    file_path = Path(path)
    if file_path.is_file():
        return str(file_path)

    downloaded = _download_drive_path(path, cfg, tmp_dir, push)
    if downloaded:
        return downloaded

    push(f"⚠ Logo path không hợp lệ: {path}", "warn")
    return None


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


@router.get("/gdrive/status")
async def gdrive_status():
    """Check if Google Drive token is valid (no browser needed)."""
    if not TOKEN_FILE.exists():
        return {"connected": False, "reason": "No token. Click Connect to authenticate."}
    try:
        if not GDRIVE_OK_CHECK():
            return {"connected": False, "reason": "Google Drive libraries not installed."}
        from google.oauth2.credentials import Credentials
        from google.auth.transport.requests import Request
        creds = Credentials.from_authorized_user_file(str(TOKEN_FILE))
        if creds and creds.valid:
            return {"connected": True}
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
            with open(TOKEN_FILE, "w") as f:
                f.write(creds.to_json())
            return {"connected": True}
        return {"connected": False, "reason": "Token expired. Click Connect to re-authenticate."}
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
        import tempfile

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


def _lark_field_map(cfg: dict) -> dict:
    return {
        "link":       cfg.get("lark_field_link",       "Link"),
        "link_completed": cfg.get("lark_field_link_completed", "Link completed"),
        "music":      cfg.get("lark_field_music",      "Nhạc"),
        "music_name": cfg.get("lark_field_music_name", "Tên nhạc"),
        "status":     cfg.get("lark_field_status",     "Status"),
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
    try:
        record_ids = await create_lark_records(
            app_id, app_secret, items, field_map=_lark_field_map(cfg)
        )
    except Exception as exc:
        # Print full traceback to server console for debugging
        tb = traceback.format_exc()
        print("[ERROR] /records/submit exception:\n", tb)
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    await _broadcast_data_changed()
    return {"record_ids": record_ids, "count": len(record_ids)}


@router.post("/jobs")
async def start_job(body: dict):
    job_id = str(uuid.uuid4())
    loop   = asyncio.get_running_loop()
    q: asyncio.Queue = asyncio.Queue()
    _job_queues[job_id] = q

    def push(message: str, log_type: str = "info") -> None:
        asyncio.run_coroutine_threadsafe(
            q.put({"type": log_type, "message": message}), loop
        )

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

            use_logo  = body.get("use_logo", False)
            use_music = body.get("use_music", False)
            logo      = _pick_logo(body, cfg, tmp, push) if use_logo else None
            music, music_name = _pick_music(body, cfg, tmp, push) if use_music else (None, None)

            if music_name:
                lark_update({"music_name": music_name})

            lark_update({"status": "Đang xử lý..."})

            if use_logo or use_music:
                out = str(Path(tmp) / "output.mp4")
                logo_scale    = int(cfg.get("logo_scale", 150))
                logo_position = cfg.get("logo_position", "top_left")
                logo_opacity  = float(cfg.get("logo_opacity", 1.0))
                push("⏳ Chờ slot xử lý...", "info")
                with _ffmpeg_semaphore:
                    process_video(video, out, push, logo=logo, music=music,
                                  logo_scale=logo_scale, logo_position=logo_position,
                                  logo_opacity=logo_opacity)
            else:
                out = video
                push("⊘ No processing (logo + music both off)", "info")

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
        asyncio.run_coroutine_threadsafe(_broadcast_data_changed(), loop)
        asyncio.run_coroutine_threadsafe(
            q.put({"type": "done", "result": result}), loop
        )

    threading.Thread(target=worker, daemon=True).start()
    return {"job_id": job_id}


@router.get("/jobs/{job_id}")
async def get_job_status(job_id: str):
    result = _job_results.get(job_id)
    if result is None:
        return {"status": "running"}
    return result


@router.get("/lark/data")
async def get_lark_data(refresh: bool = False):
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
        return _lark_cache

    try:
        data = await asyncio.wait_for(
            fetch_lark_data(app_id, app_secret),
            timeout=75.0,
        )
    except asyncio.TimeoutError:
        if _lark_cache:
            return _lark_cache  # return stale cache on timeout rather than error
        raise HTTPException(status_code=504, detail="Lark API timeout — quá 75 giây, thử lại.")
    except Exception as exc:
        if _lark_cache:
            return _lark_cache  # return stale cache on error
        raise HTTPException(status_code=502, detail=str(exc)) from exc

    _lark_cache = data
    _lark_cache_ts = now
    return data


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
    q = _job_queues.get(job_id)
    if q is None:
        await websocket.send_json({"type": "error", "message": "Job not found"})
        await websocket.close()
        return
    try:
        total_waited = 0
        while True:
            try:
                msg = await asyncio.wait_for(q.get(), timeout=25.0)
            except asyncio.TimeoutError:
                total_waited += 25
                if total_waited >= 600:
                    await websocket.send_json({"type": "error", "message": "Job timed out"})
                    break
                # Keepalive ping — prevents Railway proxy from closing idle WS
                await websocket.send_json({"type": "ping"})
                continue
            total_waited = 0
            await websocket.send_json(msg)
            if msg.get("type") == "done":
                break
    except WebSocketDisconnect:
        pass
    finally:
        _job_queues.pop(job_id, None)
