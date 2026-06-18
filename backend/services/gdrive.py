import os
from pathlib import Path
from typing import Callable

_BASE = Path(__file__).parent.parent
TOKEN_FILE = _BASE / "token.json"
CREDENTIALS_FILE = _BASE / "credentials.json"
SCOPES = ["https://www.googleapis.com/auth/drive"]

try:
    from google.auth.transport.requests import Request
    from google.oauth2.credentials import Credentials
    from google_auth_oauthlib.flow import InstalledAppFlow
    from googleapiclient.discovery import build
    from googleapiclient.errors import HttpError
    from googleapiclient.http import MediaFileUpload

    GDRIVE_OK = True
except ImportError:
    GDRIVE_OK = False


def _gdrive_service(credentials_path: str | None = None):
    if not GDRIVE_OK:
        raise RuntimeError(
            "Google Drive libs missing. "
            "Run: pip install google-api-python-client google-auth-oauthlib"
        )

    cred_file = Path(credentials_path).expanduser() if credentials_path else CREDENTIALS_FILE
    if not cred_file.exists():
        raise FileNotFoundError(
            f"credentials.json not found.\n"
            f"Expected: {cred_file}\n"
            "Fix: Go to Settings → Google Drive → set Credentials JSON path.\n"
            "Download from: Google Cloud Console → APIs & Services → Credentials → "
            "OAuth 2.0 Client IDs → Desktop app → Download JSON"
        )

    creds = None
    if TOKEN_FILE.exists():
        creds = Credentials.from_authorized_user_file(str(TOKEN_FILE), SCOPES)

    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
        else:
            flow = InstalledAppFlow.from_client_secrets_file(str(cred_file), SCOPES)
            creds = flow.run_local_server(port=0)

        with open(TOKEN_FILE, "w") as f:
            f.write(creds.to_json())

    return build("drive", "v3", credentials=creds)


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

    media = MediaFileUpload(src, mimetype="video/mp4", resumable=True)

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
