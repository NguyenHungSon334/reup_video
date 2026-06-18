import asyncio
import random
import shutil
import tempfile
import threading
import uuid
from pathlib import Path
from typing import Any

from fastapi import APIRouter, HTTPException, WebSocket, WebSocketDisconnect

from ..config import load_config, save_config
from ..services.downloader import download_video
from ..services.gdrive import TOKEN_FILE, upload_gdrive, _gdrive_service
from ..services.lark import (
    create_lark_records,
    fetch_lark_data,
    get_field_names,
    update_lark_record_sync,
)
from ..services.processor import process_video

router = APIRouter()

_job_queues:  dict[str, asyncio.Queue] = {}
_job_results: dict[str, dict[str, Any]] = {}

_AUDIO_EXTS = {".mp3", ".aac", ".wav", ".ogg", ".m4a", ".flac"}


# ── Helpers ───────────────────────────────────────────────────────────────────

def _pick_logo(body: dict, cfg: dict) -> str | None:
    path = body.get("logo_path", "").strip() or cfg.get("logo_path", "").strip()
    return path if path else None


def _pick_music(body: dict, cfg: dict, push) -> tuple[str | None, str | None]:
    """Returns (file_path, file_name). Logs the chosen track."""
    folder = cfg.get("music_folder", "").strip()
    if folder:
        p = Path(folder)
        if p.is_dir():
            files = [f for f in p.iterdir() if f.suffix.lower() in _AUDIO_EXTS]
            if files:
                chosen = random.choice(files)
                push(f"♪ Music: {chosen.name}", "info")
                return str(chosen), chosen.name
            push("⚠ Music folder has no audio files", "warn")
    path = body.get("music_path", "").strip()
    if path:
        return path, Path(path).name
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
        raise HTTPException(status_code=502, detail=str(exc)) from exc
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
            logo      = _pick_logo(body, cfg) if use_logo else None
            music, music_name = _pick_music(body, cfg, push) if use_music else (None, None)

            if music_name:
                lark_update({"music_name": music_name})

            lark_update({"status": "Đang xử lý..."})

            if use_logo or use_music:
                out = str(Path(tmp) / "output.mp4")
                logo_scale    = int(cfg.get("logo_scale", 150))
                logo_position = cfg.get("logo_position", "top_left")
                logo_opacity  = float(cfg.get("logo_opacity", 1.0))
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
                _DEFAULT_FOLDER = "1sCqlg4vQs2TlaiqlFUdrg9uAP7pQwxeh"
                folder_id        = (body.get("gdrive_folder_id", "") or cfg.get("gdrive_folder_id", "") or _DEFAULT_FOLDER).strip()
                credentials_path = cfg.get("gdrive_credentials_path", "").strip() or None
                push(f"📁 Drive folder ID: {folder_id}", "info")
                link = upload_gdrive(out, folder_id, push, credentials_path=credentials_path)
                push(f"▶ Updating Lark field '{fm.get('link')}' with Drive link...", "info")
                lark_update({"link": link})
                result = {"status": "success", "link": link}

            lark_update({"status": "Hoàn thành ✓"})

        except Exception as exc:
            push(f"✗ ERROR: {exc}", "error")
            lark_update({"status": f"Lỗi: {exc}"})
            result = {"status": "error", "message": str(exc)}
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

        _job_results[job_id] = result
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
async def get_lark_data():
    cfg        = load_config()
    app_id     = cfg.get("lark_app_id", "").strip()
    app_secret = cfg.get("lark_app_secret", "").strip()
    if not app_id or not app_secret:
        raise HTTPException(
            status_code=400,
            detail="Lark credentials not configured. Go to Settings page.",
        )
    try:
        data = await fetch_lark_data(app_id, app_secret)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return data


@router.websocket("/ws/{job_id}")
async def ws_logs(websocket: WebSocket, job_id: str):
    await websocket.accept()
    q = _job_queues.get(job_id)
    if q is None:
        await websocket.send_json({"type": "error", "message": "Job not found"})
        await websocket.close()
        return
    try:
        while True:
            msg = await asyncio.wait_for(q.get(), timeout=600.0)
            await websocket.send_json(msg)
            if msg.get("type") == "done":
                break
    except asyncio.TimeoutError:
        await websocket.send_json({"type": "error", "message": "Job timed out"})
    except WebSocketDisconnect:
        pass
    finally:
        _job_queues.pop(job_id, None)
