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
    "gdrive_credentials_path": "",
    "save_to": "drive",
    "local_folder": "",
    "lark_app_id": "",
    "lark_app_secret": "",
    "lark_field_link":       "Link video Douyin",
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
    CONFIG_FILE.write_text(json.dumps(cfg, indent=2), encoding="utf-8")
