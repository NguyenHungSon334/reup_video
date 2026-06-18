from __future__ import annotations

from datetime import datetime

import httpx

LARK_BASE         = "https://open.larksuite.com/open-apis"
BITABLE_APP_TOKEN = "DLJfboBx0aKN5lsLV9tlGVVOgrd"
TABLE_ID          = "tblpyV8NmdLgNdnd"

# Field names in the Lark table
F_LINK       = "Link video Douyin"
F_MUSIC      = "Nhạc"
F_MUSIC_NAME = "Tên Nhạc"
F_STATUS     = "Status"


# ── Token helpers ─────────────────────────────────────────────────────────────

async def _get_token(app_id: str, app_secret: str) -> str:
    async with httpx.AsyncClient() as client:
        res = await client.post(
            f"{LARK_BASE}/auth/v3/app_access_token/internal",
            json={"app_id": app_id, "app_secret": app_secret},
            timeout=10.0,
        )
        data = res.json()
        if data.get("code") != 0:
            raise RuntimeError(f"Lark auth failed: {data.get('msg', 'unknown')}")
        return data["app_access_token"]


def _get_token_sync(app_id: str, app_secret: str) -> str:
    with httpx.Client() as client:
        res = client.post(
            f"{LARK_BASE}/auth/v3/app_access_token/internal",
            json={"app_id": app_id, "app_secret": app_secret},
            timeout=10.0,
        )
        data = res.json()
        if data.get("code") != 0:
            raise RuntimeError(f"Lark auth failed: {data.get('msg', 'unknown')}")
        return data["app_access_token"]


# ── Fetch records ─────────────────────────────────────────────────────────────

async def fetch_lark_data(app_id: str, app_secret: str) -> dict:
    token   = await _get_token(app_id, app_secret)
    headers = {"Authorization": f"Bearer {token}"}

    async with httpx.AsyncClient() as client:
        f_res = await client.get(
            f"{LARK_BASE}/bitable/v1/apps/{BITABLE_APP_TOKEN}/tables/{TABLE_ID}/fields",
            headers=headers,
            timeout=10.0,
        )
        f_data = f_res.json()
        if f_data.get("code") != 0:
            raise RuntimeError(f"Lark fields error: {f_data.get('msg')}")

        field_items = (f_data.get("data") or {}).get("items") or []
        field_names = [f["field_name"] for f in field_items]
        field_types = {f["field_name"]: f.get("type") for f in field_items}

        all_records: list[dict] = []
        page_token: str | None = None

        while True:
            params: dict = {"page_size": 100}
            if page_token:
                params["page_token"] = page_token

            r_res = await client.get(
                f"{LARK_BASE}/bitable/v1/apps/{BITABLE_APP_TOKEN}/tables/{TABLE_ID}/records",
                headers=headers,
                params=params,
                timeout=20.0,
            )
            r_data = r_res.json()
            if r_data.get("code") != 0:
                raise RuntimeError(f"Lark records error: {r_data.get('msg')}")

            r_data_block = r_data.get("data") or {}
            for item in r_data_block.get("items") or []:
                raw = item.get("fields") or {}
                row = {
                    name: _stringify(raw.get(name), field_types.get(name))
                    for name in field_names
                }
                row["_record_id"] = item.get("record_id", "")
                all_records.append(row)

            if not r_data_block.get("has_more", False):
                break
            page_token = r_data_block.get("page_token")

    return {
        "fields": field_names,
        "records": all_records,
        "total": len(all_records),
    }


# ── Create records ────────────────────────────────────────────────────────────

async def get_field_names(app_id: str, app_secret: str) -> list[dict]:
    """Return raw field list: [{field_name, type, field_id}]."""
    token   = await _get_token(app_id, app_secret)
    headers = {"Authorization": f"Bearer {token}"}
    async with httpx.AsyncClient() as client:
        res = await client.get(
            f"{LARK_BASE}/bitable/v1/apps/{BITABLE_APP_TOKEN}/tables/{TABLE_ID}/fields",
            headers=headers,
            timeout=10.0,
        )
        data = res.json()
        if data.get("code") != 0:
            raise RuntimeError(f"Lark fields error: {data.get('msg')}")
        return [
            {"field_name": f["field_name"], "type": f.get("type")}
            for f in (data.get("data") or {}).get("items") or []
        ]


async def create_lark_records(
    app_id: str,
    app_secret: str,
    items: list[dict],
    field_map: dict | None = None,
) -> list[str]:
    """Create records and return list of record_ids.

    field_map overrides the default F_* constants, e.g.:
    {"link": "Video URL", "music": "Nhạc", "status": "Trạng thái"}
    """
    fm = {
        "link":       (field_map or {}).get("link",       F_LINK),
        "music":      (field_map or {}).get("music",      F_MUSIC),
        "status":     (field_map or {}).get("status",     F_STATUS),
    }

    token   = await _get_token(app_id, app_secret)
    headers = {"Authorization": f"Bearer {token}"}

    async with httpx.AsyncClient() as client:
        # Fetch existing field names so we never write to a non-existent field
        f_res = await client.get(
            f"{LARK_BASE}/bitable/v1/apps/{BITABLE_APP_TOKEN}/tables/{TABLE_ID}/fields",
            headers=headers,
            timeout=10.0,
        )
        available = {f["field_name"] for f in (f_res.json().get("data") or {}).get("items") or []}

        records_payload = []
        for item in items:
            fields: dict = {}
            if fm["link"]   in available:
                fields[fm["link"]]   = item["url"]
            if fm["music"]  in available:
                fields[fm["music"]]  = item["use_music"]
            if fm["status"] in available:
                fields[fm["status"]] = "Chờ xử lý"
            records_payload.append({"fields": fields})

        res = await client.post(
            f"{LARK_BASE}/bitable/v1/apps/{BITABLE_APP_TOKEN}/tables/{TABLE_ID}/records/batch_create",
            headers=headers,
            json={"records": records_payload},
            timeout=20.0,
        )
        data = res.json()
        if data.get("code") != 0:
            raise RuntimeError(f"Lark create error: {data.get('msg')}")

    return [r["record_id"] for r in data.get("data", {}).get("records", [])]


# ── Update a single record (sync — for use from worker threads) ───────────────

def update_lark_record_sync(
    app_id: str,
    app_secret: str,
    record_id: str,
    fields: dict,
) -> str | None:
    """Returns error message string on failure, None on success."""
    try:
        token = _get_token_sync(app_id, app_secret)
        # Wrap URL strings as Lark URL field objects
        wrapped = {
            k: {"link": v, "text": v} if isinstance(v, str) and v.startswith("http") else v
            for k, v in fields.items()
        }
        with httpx.Client() as client:
            res = client.put(
                f"{LARK_BASE}/bitable/v1/apps/{BITABLE_APP_TOKEN}"
                f"/tables/{TABLE_ID}/records/{record_id}",
                headers={"Authorization": f"Bearer {token}"},
                json={"fields": wrapped},
                timeout=15.0,
            )
            data = res.json()
            if data.get("code") != 0:
                return f"Lark update error: {data.get('msg')} (code={data.get('code')})"
        return None
    except Exception as exc:
        return f"Lark update exception: {exc}"


# ── Field stringify ───────────────────────────────────────────────────────────

_DATE_TYPES = {5, 1001, 1002}


def _stringify(val: object, field_type: int | None = None) -> str:
    if val is None:
        return ""
    if isinstance(val, bool):
        return "Yes" if val else "No"
    if isinstance(val, str):
        return val
    if isinstance(val, (int, float)):
        if field_type in _DATE_TYPES and val > 1_000_000_000_000:
            return datetime.fromtimestamp(val / 1000).strftime("%Y-%m-%d %H:%M")
        return str(int(val) if isinstance(val, float) and val == int(val) else val)
    if isinstance(val, list):
        parts: list[str] = []
        for item in val:
            if isinstance(item, dict):
                parts.append(
                    item.get("text") or item.get("name") or item.get("en_name") or str(item)
                )
            else:
                parts.append(str(item))
        return ", ".join(parts)
    if isinstance(val, dict):
        return val.get("text") or val.get("name") or val.get("link") or str(val)
    return str(val)
