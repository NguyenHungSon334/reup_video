import json
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
    # Drive folder IDs for specific purposes
    "music_gdrive_folder_id": "",
    "logo_gdrive_folder_id": "",
    "reup_gdrive_folder_id": "1Oi3Rx1_nMfOIMh-L8iiJ1Z2d34YKJMxy",
    "gdrive_credentials_path": "",
    "save_to": "drive",
    "local_folder": "",
    "lark_app_id": "",
    "lark_app_secret": "",
    "lark_field_link":       "Link video Douyin",
    "lark_field_link_completed": "Link video hoàn thành",
    "lark_field_music":      "Nhạc",
    "lark_field_music_name": "Tên Nhạc",
    "lark_field_status":     "Status",
}


def load_config() -> dict[str, Any]:
    cfg = dict(_DEFAULTS)
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
