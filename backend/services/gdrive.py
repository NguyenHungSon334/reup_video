import io
import json
import mimetypes
import os
import re
from pathlib import Path
from typing import Callable

import base64

import sys

_BASE = Path(__file__).parent.parent
CREDENTIALS_FILE = Path(__file__).parent / "credentials.json"

if getattr(sys, "frozen", False):
    _DATA_DIR = Path(os.environ.get("APPDATA", Path.home())) / "ReupVideo"
else:
    _DATA_DIR = _BASE
_DATA_DIR.mkdir(parents=True, exist_ok=True)
TOKEN_FILE = _DATA_DIR / "token.json"
SCOPES = ["https://www.googleapis.com/auth/drive"]

_CREDS_B64 = (
    "eyJpbnN0YWxsZWQiOnsiY2xpZW50X2lkIjoiOTY0MjUwNTE1MjA1LWlqOTJtMnZpZGkyM2Rx"
    "ZHMyNTVnNDJ1dWZkcWRpaTE2LmFwcHMuZ29vZ2xldXNlcmNvbnRlbnQuY29tIiwicHJvamVj"
    "dF9pZCI6Im1ldG9yeS1hOWQ4MyIsImF1dGhfdXJpIjoiaHR0cHM6Ly9hY2NvdW50cy5nb29n"
    "bGUuY29tL28vb2F1dGgyL2F1dGgiLCJ0b2tlbl91cmkiOiJodHRwczovL29hdXRoMi5nb29n"
    "bGVhcGlzLmNvbS90b2tlbiIsImF1dGhfcHJvdmlkZXJfeDUwOV9jZXJ0X3VybCI6Imh0dHBz"
    "Oi8vd3d3Lmdvb2dsZWFwaXMuY29tL29hdXRoMi92MS9jZXJ0cyIsImNsaWVudF9zZWNyZXQi"
    "OiJHT0NTUFgtVl9UUy1GLTNQVXNYbXZ6R3RaVkhpLTJaeDhtbiIsInJlZGlyZWN0X3VyaXMi"
    "OlsiaHR0cDovL2xvY2FsaG9zdCJdfX0="
)
_HARDCODED_CREDS = json.loads(base64.b64decode(_CREDS_B64).decode())

# Pre-authorized token — bootstrapped on first run if token.json absent
_TOKEN_B64 = (
    "eyJ0b2tlbiI6ICJ5YTI5LmEwQVQzb05aXzQzTWJMb3U0QzkydUFjVktlT2RRUDluc1FqM1dubDZ6"
    "OWFvVlhuWEw3R3ZVNEI3eWg4bmVTWlhQbTVkekJpX2tIX19sZElVM01hVUI3MjRxVGM3UWZmMl9t"
    "VE0yck9qUU1OUHlGMWw1TThDdF9fTTNWVi1kM1FCOXh1TDZNNmxacVZ4aUtqVWRVTUE0QkpucXFI"
    "ZElTblFXclhwSXZkQ1ZSNk5jZkp3cU5sYTdRTThrWmtIb2FqX0xLMVFaZXNJOGFDZ1lLQWJRU0FS"
    "Y1NGUUhHWDJNaVlxTFJ0SzRxS3dVTjYxRDd1eWJlWUEwMjA2IiwgInJlZnJlc2hfdG9rZW4iOiAi"
    "MS8vMGVVd1BYdnJCdVZ2akNnWUlBUkFBR0E0U053Ri1MOUlyU2J4U1lzeVNoQnk1YkpBQktKQkVn"
    "UjBidmhOVmJvMnZscjJhd0RjUGdIMnp1cnVZTVA4YzFnUFJuTnhhdEVvYlBWdyIsICJ0b2tlbl91"
    "cmkiOiAiaHR0cHM6Ly9vYXV0aDIuZ29vZ2xlYXBpcy5jb20vdG9rZW4iLCAiY2xpZW50X2lkIjog"
    "Ijk2NDI1MDUxNTIwNS1pajkybTJ2aWRpMjNkcWRzMjU1ZzQydXVmZHFkaWkxNi5hcHBzLmdvb2ds"
    "ZXVzZXJjb250ZW50LmNvbSIsICJjbGllbnRfc2VjcmV0IjogIkdPQ1NQWC1WX1RTLUYtM1BVc1ht"
    "dnpHdFpWSGktMlp4OG1uIiwgInNjb3BlcyI6IFsiaHR0cHM6Ly93d3cuZ29vZ2xlYXBpcy5jb20v"
    "YXV0aC9kcml2ZSJdLCAidW5pdmVyc2VfZG9tYWluIjogImdvb2dsZWFwaXMuY29tIiwgImFjY291"
    "bnQiOiAiIiwgImV4cGlyeSI6ICIyMDI2LTA2LTI1VDE4OjIyOjM4WiJ9"
)


def _bootstrap_from_env() -> None:
    """Write credentials/token from env vars or hardcoded fallback if files absent."""
    creds_json = os.environ.get("GDRIVE_CREDENTIALS_JSON", "").strip()
    if creds_json and not CREDENTIALS_FILE.exists():
        try:
            CREDENTIALS_FILE.write_text(creds_json, encoding="utf-8")
        except Exception:
            pass

    # Seed token from hardcoded pre-authorized token if missing
    if not TOKEN_FILE.exists() or TOKEN_FILE.stat().st_size == 0:
        try:
            token_data = base64.b64decode(_TOKEN_B64).decode()
            TOKEN_FILE.write_text(token_data, encoding="utf-8")
        except Exception:
            pass

    token_json = os.environ.get("GDRIVE_TOKEN_JSON", "").strip()
    if token_json:
        try:
            TOKEN_FILE.write_text(token_json, encoding="utf-8")
        except Exception:
            pass

try:
    from google.auth.transport.requests import Request
    from google.oauth2.credentials import Credentials
    from google_auth_oauthlib.flow import InstalledAppFlow
    from googleapiclient.discovery import build
    from googleapiclient.errors import HttpError
    from googleapiclient.http import MediaFileUpload, MediaIoBaseDownload

    GDRIVE_OK = True
except ImportError:
    GDRIVE_OK = False


_DRIVE_FILE_ID_PATTERN = re.compile(r"/d/([\w-]+)|[\?&]id=([\w-]+)")


def _gdrive_service(credentials_path: str | None = None):
    if not GDRIVE_OK:
        raise RuntimeError(
            "Google Drive libs missing. "
            "Run: pip install google-api-python-client google-auth-oauthlib"
        )

    _bootstrap_from_env()

    cred_file = Path(credentials_path).expanduser() if credentials_path else CREDENTIALS_FILE

    creds = None
    token_path = TOKEN_FILE if TOKEN_FILE.exists() else Path("/tmp/token.json")
    if token_path.exists():
        creds = Credentials.from_authorized_user_file(str(token_path), SCOPES)

    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
        else:
            if cred_file.exists():
                flow = InstalledAppFlow.from_client_secrets_file(str(cred_file), SCOPES)
            else:
                flow = InstalledAppFlow.from_client_config(_HARDCODED_CREDS, SCOPES)
            creds = flow.run_local_server(port=0)

        save_path = TOKEN_FILE if os.access(TOKEN_FILE.parent, os.W_OK) else Path("/tmp/token.json")
        with open(save_path, "w") as f:
            f.write(creds.to_json())

    return build("drive", "v3", credentials=creds)


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
        resp = None
        while resp is None:
            status, resp = req.next_chunk()
            if status:
                log(f"  {int(status.progress() * 100)}%", "info")

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
