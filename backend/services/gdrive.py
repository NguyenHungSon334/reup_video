import io
import json
import mimetypes
import os
import re
import threading
from pathlib import Path
from typing import Callable

from backend.services.progress import throttled

import base64

import sys

_BASE = Path(__file__).parent.parent
CREDENTIALS_FILE = Path(__file__).parent / "credentials.json"

if getattr(sys, "frozen", False):
    if sys.platform == "darwin":
        _DATA_DIR = Path.home() / "Library" / "Application Support" / "ReupVideo"
    else:
        _DATA_DIR = Path(os.environ.get("APPDATA", Path.home())) / "ReupVideo"
else:
    _DATA_DIR = _BASE
_DATA_DIR.mkdir(parents=True, exist_ok=True)
TOKEN_FILE = _DATA_DIR / "token.json"
SCOPES = ["https://www.googleapis.com/auth/drive"]

# Service account (robot identity) — no browser, no user login, no token expiry.
# Share the Drive folders / Shared Drive with reupbot@metory-a9d83.iam.gserviceaccount.com.
_SA_B64 = (
    "ewogICJ0eXBlIjogInNlcnZpY2VfYWNjb3VudCIsCiAgInByb2plY3RfaWQiOiAibWV0b3J5LWE5ZDgzIiwKICAicHJpdmF0ZV9rZXlfaWQiOiAiZWUyZmQ2ODEyNjMxZTk3MmIwOGUwYmIxOGZlZDE2ZmY4MThhOTAxZCIsCiAgInByaXZhdGVfa2V5IjogIi0tLS0tQkVHSU4gUFJJVkFURSBLRVktLS0tLVxuTUlJRXZRSUJBREFOQmdrcWhraUc5dzBCQVFFRkFBU0NCS2N3Z2dTakFnRUFBb0lCQVFEVUptQTY0NDBmK2lOU1xudUJGenVhL0NHa2hzT3V1anNkK2dSN0Y1VUNwSlFVRllwaytQZ0x3c1loOG9RVHY3VlZsRythamdzYTd1MW1PcFxuYVhzOVh6NFF1eUNZczhDa1c2cW9pWEc0ejh2YWtjckR1S3g5MGZXcVBsVDhEMW1LTmIwc1hEZU5id2JZbUQ4a1xuV3EvdE1rVlc4U29hTjF6WnY0b21rWSt1R2taMzFBUmlUWlhjQjgyT29ENUV2b1psZ2xPUDh2YTBYOWk2YW1RM1xuTFZYSjJVVnlmbnhmVXpPSUZKQ29vOHBIa0xGeEEwZUdXc1NoSTZiemJja2xZVVQ1VDNYWjJCSndWS3I3YVh5dFxubEhyeWkvT3ljR1VqTWdXdlpiMVI5Z3QrWUt6YlV3SklUaTlzcmJYcE93ZC9ESURPdTlzaW9MY1ozdHVwZUZWd1xuS21JNVFQRlpBZ01CQUFFQ2dnRUFCSFhPd0hPSDd0d0JseHZJazNyR3Y2N0d4cTVuR3RqQ3FmOTlNelE2RjEwdFxucndhY0ZlNXZ4bGZGR094azJFVmZRYUhwRTRSRGVHdW9kUkl0MEVpcTA0dU9SV0pEYUJFeDl0RExtUnVXbm10QlxuN0kzUU9UcjErUlRPRU8zbEJOdFpYL3FMcm5KZTgwOGhjTFc1WWlRVVFoNHRpT3lRdHF2b3VjNkY5ZlByekZsdVxuY29iTisxZEJqRzQvWFpSNFE5T3dkVjF1bGs1c3JRYmppSW4rTTBQcHhzbmQ3YjU3ZlJYNTV3alRBUVJlTnFsTVxuMGxTSXB5VHFLWW84Y25NRHdvazI3OEZhWFZKSWN6dDZORFEvVlE2T21PNU9RQUJYZWVpemJRcVovd2hUem9DK1xuUWZ6a2dtRWlJS3lOUDVSdkZwUlZzMlUrWEZxNGxLWmpML0I4dW9mekl3S0JnUUQyRjl3SWllRjRiZlNra2NZOVxucXJVK3BZYzhTNFBtbGhpZXVJMW1EZXZsN1ZRbHpuVHBPQlovRHR4Rjk4UkFlSjljOXFGUityMkVSVXZPR200UVxuMERqTHRqRXFqRmlCTWE4Y3VaMUpSY1JENDZlTlNWNGJtN3I4RWw2YXRQNEY2K0V2NFNXdERMSWJ4UEh5dXhxRlxuamlmbXFPazBnVGJGR3dFdmVRS1hRWVpmQXdLQmdRRGNzTFhGQ0pkUm4rc21pU29yUWFOQlAraWYrMXdHempoMVxuN0pUMStPai93K2htcmNiT0w2T1dPbXdncVBtVUhKNWFhMDIvNE5ua3FhbFdhK0hheUNNZVJPc0tjcDdIbnhIV1xuQm9ZSkpTcllBU2R4Y3hoSzVMaEpkTG1XOFlVT0JmcWRTSkQ5b2dud005UUt6UHdMbVo3MVBPREZsdkF3cjJ0eFxuTnhtTVNjSEJjd0tCZ0haenk1Uk1rYnQrNlllaEp4T2RySG5JQVEwVHFCeUFXTDlsUTZKQXh6QTRDUTNkajBhR1xubWNWMHFMQUE3M1M4MnJCTGdpRE1tUlltcUxNKzQ0V3lRL1JCOE81eStWTE9VR1I2TDJ3S2Fjcm50RWw4YkJETFxuNTdmWE83UXB0Qyt6ZHdPdDBvMjJFN0RzSGkxZ3hBWlBBNE94Ly9ZbXorOFY3WDhsTndzSkhoMXpBb0dBZlZYT1xucGN3dlJDZ3lnSHc5K3JzWVlLSlBGeXpHSXdkVGdZV1BRL0xOUVJTZUZGSjFLZnhjUjZGK2J6NElJRm53aFNHVFxuMG5sOHhpU2xDM1BSblZNMHZxZ2RaSjJjRjNyN3dqV0tRZjlkeWJjK0UyeHVTM3FDUHhXUG9XNGhSc21XZjJVTFxuRTBESHJDZURNVzhoWmVVbEpkb2hQWlp2YXZiMWFpTUUyMnU0SW9rQ2dZRUE1VE1xRENmeUNFZnV0RW40VGEwR1xud1hOcEY5RGpIRlduKzhJeGQvbU8rKzVtdENYYlFUNW5NcnZGZU9RTTdDTW9uWXdTeDNIT2RjNXkvcURyckp6clxuSUdBdkNXWEZrdjk1VnBJMm5XcVN1VDB0NmlrRHlmTzFhc2dmcm8zMHhuUnlOOHFyWUJUU3dIS3ZQZm92UHI0VlxuOUY2UUs3Q3czZGg0UktFMWl5c1JCd2M9XG4tLS0tLUVORCBQUklWQVRFIEtFWS0tLS0tXG4iLAogICJjbGllbnRfZW1haWwiOiAicmV1cGJvdEBtZXRvcnktYTlkODMuaWFtLmdzZXJ2aWNlYWNjb3VudC5jb20iLAogICJjbGllbnRfaWQiOiAiMTE2NDg0Njg1NzA3NDEzMzUwNzM4IiwKICAiYXV0aF91cmkiOiAiaHR0cHM6Ly9hY2NvdW50cy5nb29nbGUuY29tL28vb2F1dGgyL2F1dGgiLAogICJ0b2tlbl91cmkiOiAiaHR0cHM6Ly9vYXV0aDIuZ29vZ2xlYXBpcy5jb20vdG9rZW4iLAogICJhdXRoX3Byb3ZpZGVyX3g1MDlfY2VydF91cmwiOiAiaHR0cHM6Ly93d3cuZ29vZ2xlYXBpcy5jb20vb2F1dGgyL3YxL2NlcnRzIiwKICAiY2xpZW50X3g1MDlfY2VydF91cmwiOiAiaHR0cHM6Ly93d3cuZ29vZ2xlYXBpcy5jb20vcm9ib3QvdjEvbWV0YWRhdGEveDUwOS9yZXVwYm90JTQwbWV0b3J5LWE5ZDgzLmlhbS5nc2VydmljZWFjY291bnQuY29tIiwKICAidW5pdmVyc2VfZG9tYWluIjogImdvb2dsZWFwaXMuY29tIgp9Cg=="
)
_SA_INFO = json.loads(base64.b64decode(_SA_B64).decode())

try:
    from google.oauth2.service_account import Credentials as ServiceAccountCredentials
    from googleapiclient.discovery import build
    from googleapiclient.errors import HttpError
    from googleapiclient.http import MediaFileUpload, MediaIoBaseDownload

    GDRIVE_OK = True
except ImportError:
    GDRIVE_OK = False


_DRIVE_FILE_ID_PATTERN = re.compile(r"/d/([\w-]+)|[\?&]id=([\w-]+)")


# Cache built Drive services PER THREAD. A googleapiclient service wraps a single
# httplib2.Http/auth session that is NOT thread-safe — sharing one across worker
# threads makes concurrent .execute() calls collide on the same TLS socket
# ("SSL: MIXED_HANDSHAKE_AND_NON_HANDSHAKE_DATA" / "UNEXPECTED_RECORD"). Thread-local
# gives each worker its own service+socket; still cached so one survives a batch.
# ponytail: never invalidated; a revoked token surfaces as an API error and the
# user re-auths (deletes token.json) — add explicit eviction only if that hurts.
_service_cache = threading.local()


def _gdrive_service(credentials_path: str | None = None):
    if not GDRIVE_OK:
        raise RuntimeError(
            "Google Drive libs missing. "
            "Run: pip install google-api-python-client google-auth-oauthlib"
        )

    cache_key = credentials_path or "__default__"
    cache = getattr(_service_cache, "services", None)
    if cache is None:
        cache = _service_cache.services = {}
    cached = cache.get(cache_key)
    if cached is not None:
        return cached

    # Service account auth: no browser, no user login, no token expiry.
    # Use a caller-supplied service_account JSON if given, else the baked-in one.
    info = _SA_INFO
    if credentials_path:
        p = Path(credentials_path).expanduser()
        if p.is_file():
            try:
                loaded = json.loads(p.read_text(encoding="utf-8"))
                if loaded.get("type") == "service_account":
                    info = loaded
            except Exception:
                pass  # fall back to baked-in service account

    creds = ServiceAccountCredentials.from_service_account_info(info, scopes=SCOPES)
    svc = build("drive", "v3", credentials=creds)
    cache[cache_key] = svc
    return svc


def _extract_drive_file_id(value: str) -> str | None:
    value = value.strip()
    if not value:
        return None

    if re.fullmatch(r"[\w-]{20,}", value):
        return value

    match = _DRIVE_FILE_ID_PATTERN.search(value)
    if match:
        return match.group(1) or match.group(2)

    if "drive.google.com" in value:
        candidates = re.findall(r"[\w-]{20,}", value)
        if candidates:
            return candidates[-1]

    return None


def download_gdrive_file(file_id: str, destination_path: str, credentials_path: str | None = None) -> None:
    if not GDRIVE_OK:
        raise RuntimeError("Google Drive libs missing. Run: pip install google-api-python-client google-auth-oauthlib")
    svc = _gdrive_service(credentials_path)
    request = svc.files().get_media(fileId=file_id, supportsAllDrives=True)
    with open(destination_path, "wb") as fh:
        downloader = MediaIoBaseDownload(fh, request)
        done = False
        while not done:
            status, done = downloader.next_chunk()


def upload_gdrive(src: str, folder_id: str, log: Callable[[str, str], None],
                  credentials_path: str | None = None) -> str:
    log("▶ Connecting to Google Drive...", "info")

    try:
        svc = _gdrive_service(credentials_path)
        log("✓ Authenticated OK", "info")
    except Exception as e:
        log(f"❌ Authentication error: {e}", "error")
        raise

    clean_folder_id = folder_id.strip() if folder_id else ""

    if clean_folder_id:
        try:
            folder_meta = svc.files().get(
                fileId=clean_folder_id, fields="id,name",
                supportsAllDrives=True
            ).execute()
            log(f"✓ Folder found: {folder_meta.get('name', clean_folder_id)}", "info")
        except HttpError as e:
            log(f"❌ Folder not found (ID: {clean_folder_id}): HTTP {e.resp.status}", "error")
            log(f"   Detail: {e.content.decode()}", "error")
            log("Kiem tra folder ID trong Settings → Google Drive Folder ID", "info")
            raise

    name = Path(src).name
    file_metadata: dict = {"name": name}
    if clean_folder_id:
        file_metadata["parents"] = [clean_folder_id]

    log(f"▶ Uploading {name}...", "info")

    mime_type, _ = mimetypes.guess_type(src)
    if not mime_type:
        mime_type = "application/octet-stream"
    media = MediaFileUpload(src, mimetype=mime_type, resumable=True)

    try:
        req = svc.files().create(
            body=file_metadata, media_body=media, fields="id,name,webViewLink",
            supportsAllDrives=True
        )
        emit = throttled(log)
        resp = None
        while resp is None:
            status, resp = req.next_chunk()
            if status:
                pct = status.progress() * 100
                emit(f"  {int(pct)}%", "info", pct=pct)

        log(f"✓ File Name: {resp.get('name')}", "info")
        log(f"✓ File ID:   {resp.get('id')}", "info")
        link = resp.get("webViewLink", "https://drive.google.com")
        log(f"✓ Link: {link}", "success")
        return link

    except HttpError as error:
        log(f"❌ Upload failed: HTTP {error.resp.status}", "error")
        log(f"   Detail: {error.content.decode()}", "error")
        if error.resp.status == 403:
            log("💡 Permission denied — kiểm tra quyền truy cập folder", "info")
        elif error.resp.status == 404:
            log(f"💡 Not found — xóa {TOKEN_FILE} và chạy lại để re-auth", "info")
        raise
    except Exception as e:
        log(f"❌ Unexpected upload error: {type(e).__name__}: {e}", "error")
        raise


def list_folder_files(folder_id: str, credentials_path: str | None = None):
    """Return list of files in a Drive folder. Each entry: id, name, mimeType, webViewLink"""
    if not GDRIVE_OK:
        raise RuntimeError("Google Drive libs missing. Run: pip install google-api-python-client google-auth-oauthlib")

    svc = _gdrive_service(credentials_path)
    fid = folder_id.strip()
    q = f"'{fid}' in parents and trashed = false"
    files: list[dict] = []
    page_token = None
    while True:
        resp = svc.files().list(
            q=q,
            fields="nextPageToken, files(id,name,mimeType,webViewLink)",
            supportsAllDrives=True,
            includeItemsFromAllDrives=True,
            pageToken=page_token,
        ).execute()
        files.extend(resp.get("files", []))
        page_token = resp.get("nextPageToken")
        if not page_token:
            break
    return files


def get_file_metadata(file_id: str, credentials_path: str | None = None):
    if not GDRIVE_OK:
        raise RuntimeError("Google Drive libs missing. Run: pip install google-api-python-client google-auth-oauthlib")
    svc = _gdrive_service(credentials_path)
    return svc.files().get(fileId=file_id, fields="id,name,mimeType,webViewLink", supportsAllDrives=True).execute()
