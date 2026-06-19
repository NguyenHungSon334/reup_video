import json
import os
from pathlib import Path
from typing import Any

CONFIG_FILE = Path(__file__).parent.parent / "config.json"

_DEFAULTS: dict[str, Any] = {
    "logo_path": "",
    "use_logo": True,
    "logo_scale": 150,
    "logo_position": "top_left",
    "logo_opacity": 1.0,
    "music_path": "",
    "use_music": False,
    "music_folder": "",
    "cookies_browser": "",
    "cookies_file": "",
    "gdrive_folder_id": "1sCqlg4vQs2TlaiqlFUdrg9uAP7pQwxeh",
    "music_gdrive_folder_id": "",
    "logo_gdrive_folder_id": "",
    "reup_gdrive_folder_id": "1Oi3Rx1_nMfOIMh-L8iiJ1Z2d34YKJMxy",
    "gdrive_credentials_path": "",
    "save_to": "drive",
    "local_folder": "",
    "lark_app_id": "",
    "lark_app_secret": "",
    "lark_field_link":           "Link video Douyin",
    "lark_field_link_completed": "Link video hoàn thành",
    "lark_field_music":          "Nhạc",
    "lark_field_music_name":     "Tên Nhạc",
    "lark_field_status":         "Status",
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
}


def load_config() -> dict[str, Any]:
    cfg = dict(_DEFAULTS)
    # Layer 1: env vars (set in Railway dashboard — survive restarts)
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
    return cfg


def save_config(cfg: dict[str, Any]) -> None:
    existing = load_config()
    existing.update(cfg)
    CONFIG_FILE.write_text(json.dumps(existing, indent=2), encoding="utf-8")
