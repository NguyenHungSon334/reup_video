import json
import os
from pathlib import Path
from typing import Any

try:
    from dotenv import load_dotenv
    _env_file = Path(__file__).parent.parent / ".env"
    if _env_file.exists():
        load_dotenv(_env_file, override=False)
except ImportError:
    pass

CONFIG_FILE = Path(__file__).parent.parent / "config.json"
COOKIES_STORE_FILE = Path(__file__).parent.parent / "douyin.cookies.txt"
# JSON cookie store read by the pure-API path WITHOUT launching a browser.
COOKIES_JSON_FILE = Path.home() / ".reup_video" / "douyin.cookies.json"
_BUNDLED_CREDS = Path(__file__).parent / "credentials.json"

_DEFAULTS: dict[str, Any] = {
    # ── Lark ──────────────────────────────────────────────────────────────────
    "lark_app_id":               "cli_aab92e864f78ded0",
    "lark_app_secret":           "4lKobJ2pNckhIZcJ9C3aAxVkRLmOHB1O",
    "lark_field_link":           "Link video Douyin",
    "lark_field_link_completed": "Link video hoàn thành",
    "lark_field_music":          "Nhạc",
    "lark_field_music_name":     "Tên Nhạc",
    "lark_field_status":         "Status",
    "lark_field_kenh":           "Kênh",
    # ── Google Drive ──────────────────────────────────────────────────────────
    "gdrive_folder_id":          "1sCqlg4vQs2TlaiqlFUdrg9uAP7pQwxeh",
    "reup_gdrive_folder_id":     "1Oi3Rx1_nMfOIMh-L8iiJ1Z2d34YKJMxy",
    "music_gdrive_folder_id":    "1_DdehS3H6sFHtXhc9rJNGNMbTXfD1UCU",
    "logo_gdrive_folder_id":     "1ZftQa9gtbIlEwB0NzRmLGOoGuYQLXMcE",
    # ── Media settings ────────────────────────────────────────────────────────
    "logo_path": "",
    "use_logo": True,
    "logo_scale": 150,
    "logo_position": "top_left",
    "logo_opacity": 1.0,
    "music_path": "",
    "use_music": False,
    "music_folder": "",
    "gdrive_credentials_path": str(_BUNDLED_CREDS) if _BUNDLED_CREDS.exists() else "",
    "cookies_browser": "",
    "cookies_file": "",
    "cookies_text": "",
    "save_to": "drive",
    "local_folder": "",
}

# Map env var name → config key (Railway environment variables override defaults)
_ENV_MAP = {
    "LARK_APP_ID":              "lark_app_id",
    "LARK_APP_SECRET":          "lark_app_secret",
    "GDRIVE_FOLDER_ID":         "gdrive_folder_id",
    "REUP_GDRIVE_FOLDER_ID":    "reup_gdrive_folder_id",
    "MUSIC_GDRIVE_FOLDER_ID":   "music_gdrive_folder_id",
    "LOGO_GDRIVE_FOLDER_ID":    "logo_gdrive_folder_id",
    "GDRIVE_CREDENTIALS_PATH":  "gdrive_credentials_path",
    "LARK_FIELD_LINK":          "lark_field_link",
    "LARK_FIELD_LINK_COMPLETED":"lark_field_link_completed",
    "LARK_FIELD_MUSIC":         "lark_field_music",
    "LARK_FIELD_MUSIC_NAME":    "lark_field_music_name",
    "LARK_FIELD_STATUS":        "lark_field_status",
    "LARK_FIELD_KENH":          "lark_field_kenh",
    "DOUYIN_COOKIES_BROWSER":   "cookies_browser",
    "DOUYIN_COOKIES_FILE":      "cookies_file",
}




def _read_cookie_text(path_value: str) -> str:
    path = Path(path_value)
    if not path.exists() or not path.is_file():
        return ""
    try:
        return path.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return ""


def load_config() -> dict[str, Any]:
    cfg = dict(_DEFAULTS)
    # Layer 1: env vars (set in Railway dashboard - survive restarts)
    for env_key, cfg_key in _ENV_MAP.items():
        val = os.environ.get(env_key, "").strip()
        if val:
            cfg[cfg_key] = val
    # Layer 2: config.json overrides env vars (set via Settings page)
    if CONFIG_FILE.exists():
        try:
            cfg.update(json.loads(CONFIG_FILE.read_text(encoding="utf-8")))
        except Exception:
            pass

    cookies_path = str(cfg.get("cookies_file", "")).strip()
    if cookies_path and not Path(cookies_path).exists():
        cookies_path = ""
    if not cookies_path and COOKIES_STORE_FILE.exists():
        cookies_path = str(COOKIES_STORE_FILE)
        cfg["cookies_file"] = cookies_path
    # Recover: if cookies_text is embedded in config.json but file is gone, restore it
    if not cookies_path:
        raw = str(cfg.get("cookies_text", "")).strip()
        if raw:
            COOKIES_STORE_FILE.write_text(raw + "\n", encoding="utf-8")
            cookies_path = str(COOKIES_STORE_FILE)
            cfg["cookies_file"] = cookies_path
    cfg["cookies_text"] = _read_cookie_text(cookies_path) if cookies_path else ""
    return cfg


def save_config(cfg: dict[str, Any]) -> None:
    existing = load_config()
    cookies_text = cfg.pop("cookies_text", None)
    existing.update(cfg)

    if cookies_text is not None:
        raw = str(cookies_text).replace("\r\n", "\n").strip()
        if raw:
            COOKIES_STORE_FILE.write_text(raw + "\n", encoding="utf-8")
            existing["cookies_file"] = str(COOKIES_STORE_FILE)
        else:
            if existing.get("cookies_file") == str(COOKIES_STORE_FILE):
                existing["cookies_file"] = ""
            if COOKIES_STORE_FILE.exists():
                COOKIES_STORE_FILE.unlink()

    existing.pop("cookies_text", None)
    CONFIG_FILE.write_text(json.dumps(existing, indent=2), encoding="utf-8")
