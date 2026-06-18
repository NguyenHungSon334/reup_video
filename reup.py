#!/usr/bin/env python3
"""Douyin Reup — download, watermark, upload to Google Drive."""

import json
import pickle
import shutil
import subprocess
import sys
import tempfile
import threading
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox

import customtkinter as ctk

ctk.set_appearance_mode("dark")
ctk.set_default_color_theme("blue")

APP_DIR = Path(__file__).parent
CONFIG_FILE = APP_DIR / "config.json"
TOKEN_FILE = APP_DIR / "token.pickle"
CREDENTIALS_FILE = APP_DIR / "credentials.json"
SCOPES = ["https://www.googleapis.com/auth/drive.file"]

_NO_WINDOW = subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0

try:
    from google.auth.transport.requests import Request
    from google_auth_oauthlib.flow import InstalledAppFlow
    from googleapiclient.discovery import build
    from googleapiclient.http import MediaFileUpload
    GDRIVE_OK = True
except ImportError:
    GDRIVE_OK = False

_DEST_MAP = {"drive": "☁  Google Drive", "local": "💾  Local Folder"}
_DEST_RMAP = {v: k for k, v in _DEST_MAP.items()}


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

def load_config() -> dict:
    if CONFIG_FILE.exists():
        try:
            return json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {
        "logo_path": "", "use_logo": True,
        "music_path": "", "use_music": False,
        "gdrive_folder_id": "", "save_to": "drive", "local_folder": "",
    }


def save_config(cfg: dict):
    CONFIG_FILE.write_text(json.dumps(cfg, indent=2), encoding="utf-8")


# ---------------------------------------------------------------------------
# Google Drive
# ---------------------------------------------------------------------------

def _gdrive_service():
    if not GDRIVE_OK:
        raise RuntimeError(
            "Google Drive libs missing.\n"
            "Run: pip install google-api-python-client google-auth-oauthlib"
        )
    creds = None
    if TOKEN_FILE.exists():
        with open(TOKEN_FILE, "rb") as f:
            creds = pickle.load(f)
    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
        else:
            if not CREDENTIALS_FILE.exists():
                raise FileNotFoundError(
                    f"credentials.json not found at:\n  {CREDENTIALS_FILE}\n\n"
                    "Steps:\n"
                    "  1. Go to console.cloud.google.com\n"
                    "  2. Create project → Enable Google Drive API\n"
                    "  3. APIs & Services → Credentials → Create OAuth 2.0 Client ID\n"
                    "  4. Application type: Desktop app\n"
                    "  5. Download JSON → rename to credentials.json → place next to reup.py"
                )
            flow = InstalledAppFlow.from_client_secrets_file(str(CREDENTIALS_FILE), SCOPES)
            creds = flow.run_local_server(port=0)
        with open(TOKEN_FILE, "wb") as f:
            pickle.dump(creds, f)
    return build("drive", "v3", credentials=creds)


# ---------------------------------------------------------------------------
# Pipeline steps
# ---------------------------------------------------------------------------

def download_video(url: str, out_dir: str, log) -> str:
    tpl = str(Path(out_dir) / "video.%(ext)s")
    cmd = [
        sys.executable, "-m", "yt_dlp",
        "--no-playlist", "-o", tpl,
        "--merge-output-format", "mp4",
        "--add-header", "Referer:https://www.douyin.com",
        url,
    ]
    log(f"▶ Downloading: {url[:80]}...")
    proc = subprocess.Popen(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, encoding="utf-8", errors="replace", creationflags=_NO_WINDOW,
    )
    for line in proc.stdout:
        line = line.rstrip()
        if line:
            log(line)
    proc.wait()
    if proc.returncode != 0:
        raise RuntimeError("yt-dlp failed. Check URL and network connection.")
    for ext in ("mp4", "webm", "mkv", "mov"):
        p = Path(out_dir) / f"video.{ext}"
        if p.exists():
            log(f"✓ Downloaded: {p.name}")
            return str(p)
    raise RuntimeError("Downloaded file not found in temp folder.")


def process_video(src: str, dst: str, log, logo: str = None, music: str = None) -> str:
    """Apply logo overlay and/or background music in a single ffmpeg pass."""
    if not logo and not music:
        shutil.copy2(src, dst)
        return dst

    cmd = ["ffmpeg", "-y", "-i", src]
    logo_idx = music_idx = None

    if logo:
        logo_idx = 1
        cmd += ["-i", logo]
    if music:
        music_idx = 2 if logo else 1
        cmd += ["-stream_loop", "-1", "-i", music]

    filters, maps, extra = [], [], []

    if logo:
        filters.append(f"[{logo_idx}:v]scale=150:-1[wm];[0:v][wm]overlay=10:10[vout]")
        maps += ["-map", "[vout]"]
    else:
        maps += ["-map", "0:v"]
        extra += ["-c:v", "copy"]

    if music:
        filters.append(
            f"[{music_idx}:a]volume=0.3[bg];[0:a][bg]amix=inputs=2:duration=first[aout]"
        )
        maps += ["-map", "[aout]"]
    else:
        maps += ["-map", "0:a"]
        extra += ["-c:a", "copy"]

    if filters:
        cmd += ["-filter_complex", ";".join(filters)]
    cmd += maps + extra + [dst]

    parts = (["watermark"] if logo else []) + (["background music"] if music else [])
    log(f"▶ Adding {' + '.join(parts)}...")

    proc = subprocess.Popen(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, encoding="utf-8", errors="replace", creationflags=_NO_WINDOW,
    )
    for line in proc.stdout:
        line = line.rstrip()
        if line and ("frame=" in line or "error" in line.lower()):
            log(line)
    proc.wait()
    if proc.returncode != 0:
        raise RuntimeError(
            "ffmpeg processing failed.\n"
            "Make sure ffmpeg is installed and added to PATH.\n"
            "Download: https://ffmpeg.org/download.html"
        )
    log("✓ Processing done")
    return dst


def upload_gdrive(src: str, folder_id: str, log) -> str:
    log("▶ Connecting to Google Drive...")
    svc = _gdrive_service()
    name = Path(src).name
    meta = {"name": name}
    if folder_id.strip():
        meta["parents"] = [folder_id.strip()]
    log(f"▶ Uploading {name} ...")
    media = MediaFileUpload(src, mimetype="video/mp4", resumable=True, chunksize=5 * 1024 * 1024)
    req = svc.files().create(body=meta, media_body=media, fields="id,webViewLink")
    resp = None
    while resp is None:
        status, resp = req.next_chunk()
        if status:
            log(f"  {int(status.progress() * 100)}%")
    link = resp.get("webViewLink", "https://drive.google.com")
    log(f"✓ Uploaded: {link}")
    return link


# ---------------------------------------------------------------------------
# GUI
# ---------------------------------------------------------------------------

class App(ctk.CTk):
    def __init__(self):
        super().__init__()
        self.title("Douyin Reup")
        self.geometry("700x800")
        self.minsize(580, 660)
        self._cfg = load_config()
        self._anim_running = False
        self._anim_val = 0.0
        self._build_ui()
        self.after(300, self._check_deps)

    # ── layout helpers ────────────────────────────────────────────────────────

    def _section(self, parent, title: str):
        """Create a card frame with divider; return inner body frame."""
        card = ctk.CTkFrame(parent, corner_radius=12)
        card.pack(fill="x", padx=16, pady=(0, 10))
        ctk.CTkLabel(card, text=title,
                     font=ctk.CTkFont(size=12, weight="bold"),
                     anchor="w").pack(fill="x", padx=14, pady=(10, 4))
        ctk.CTkFrame(card, height=1, corner_radius=0,
                     fg_color=("gray75", "gray30")).pack(fill="x", padx=14, pady=(0, 8))
        body = ctk.CTkFrame(card, fg_color="transparent")
        body.pack(fill="x", padx=12, pady=(0, 12))
        return body

    def _file_row(self, parent, sw_text, entry_var, browse_cmd, placeholder):
        """Toggle-switch + entry + browse button row. Returns (switch, entry, button)."""
        row = ctk.CTkFrame(parent, fg_color="transparent")
        row.pack(fill="x", pady=4)
        sw = ctk.CTkSwitch(row, text=sw_text, width=110,
                           font=ctk.CTkFont(size=12))
        sw.pack(side="left")
        ent = ctk.CTkEntry(row, textvariable=entry_var, height=34,
                           placeholder_text=placeholder,
                           font=ctk.CTkFont(size=11))
        ent.pack(side="left", fill="x", expand=True, padx=(10, 0))
        btn = ctk.CTkButton(row, text="Browse", width=82, height=34,
                            command=browse_cmd)
        btn.pack(side="left", padx=(6, 0))
        return sw, ent, btn

    # ── build ─────────────────────────────────────────────────────────────────

    def _build_ui(self):
        # ── Header ────────────────────────────────────────────────────────────
        hdr = ctk.CTkFrame(self, corner_radius=0, height=56,
                           fg_color=("gray88", "#0d1117"))
        hdr.pack(fill="x")
        hdr.pack_propagate(False)

        ctk.CTkLabel(hdr, text="  🎬  Douyin Reup",
                     font=ctk.CTkFont(size=19, weight="bold")).pack(side="left", padx=20)

        self._status_lbl = ctk.CTkLabel(
            hdr, text="●  Ready",
            font=ctk.CTkFont(size=12), text_color="gray55",
        )
        self._status_lbl.pack(side="right", padx=20)

        # ── Scrollable content ────────────────────────────────────────────────
        scroll = ctk.CTkScrollableFrame(self, fg_color="transparent",
                                        corner_radius=0, scrollbar_button_color="gray30")
        scroll.pack(fill="both", expand=True, pady=(12, 0))

        self._build_url(scroll)
        self._build_media(scroll)
        self._build_dest(scroll)
        self._build_log(scroll)

        # ── Bottom bar ────────────────────────────────────────────────────────
        bot = ctk.CTkFrame(self, corner_radius=0, height=64,
                           fg_color=("gray88", "#0d1117"))
        bot.pack(fill="x", side="bottom")
        bot.pack_propagate(False)

        self._run_btn = ctk.CTkButton(
            bot, text="▶   Process Video", width=172, height=38,
            font=ctk.CTkFont(size=13, weight="bold"),
            command=self._start,
        )
        self._run_btn.pack(side="left", padx=16, pady=13)

        ctk.CTkButton(bot, text="Clear Log", width=90, height=38,
                      fg_color="transparent", border_width=1,
                      hover_color=("gray75", "gray25"),
                      command=self._clear_log).pack(side="left", pady=13)

        ctk.CTkButton(bot, text="⚙  Save", width=90, height=38,
                      fg_color="transparent", border_width=1,
                      hover_color=("gray75", "gray25"),
                      command=self._save).pack(side="right", padx=16, pady=13)

        self._prog = ctk.CTkProgressBar(bot, height=3, corner_radius=0,
                                        progress_color="#1f6aa5")
        self._prog.pack(fill="x", side="bottom")
        self._prog.set(0)

    def _build_url(self, parent):
        body = self._section(parent, "🔗  Douyin URL")
        row = ctk.CTkFrame(body, fg_color="transparent")
        row.pack(fill="x")
        self._url_var = tk.StringVar()
        ctk.CTkEntry(row, textvariable=self._url_var, height=36,
                     placeholder_text="Paste Douyin video URL here...",
                     font=ctk.CTkFont(size=12)).pack(side="left", fill="x", expand=True)
        ctk.CTkButton(row, text="Paste", width=72, height=36,
                      command=self._paste).pack(side="left", padx=(8, 0))

    def _build_media(self, parent):
        body = self._section(parent, "🎨  Media")

        self._logo_var = tk.StringVar(value=self._cfg.get("logo_path", ""))
        self._logo_sw, self._logo_ent, self._logo_btn = self._file_row(
            body, "Logo", self._logo_var, self._browse_logo, "logo.png — placed top-left"
        )
        if self._cfg.get("use_logo", True):
            self._logo_sw.select()
        self._logo_sw.configure(command=self._toggle_logo)

        self._music_var = tk.StringVar(value=self._cfg.get("music_path", ""))
        self._music_sw, self._music_ent, self._music_btn = self._file_row(
            body, "Music", self._music_var, self._browse_music, "background.mp3 — 30% volume mix"
        )
        if self._cfg.get("use_music", False):
            self._music_sw.select()
        self._music_sw.configure(command=self._toggle_music)

        self._toggle_logo()
        self._toggle_music()

    def _build_dest(self, parent):
        body = self._section(parent, "💾  Save To")

        self._dest_seg = ctk.CTkSegmentedButton(
            body, values=list(_DEST_MAP.values()),
            command=self._on_dest_change,
            height=36, font=ctk.CTkFont(size=12),
        )
        self._dest_seg.pack(fill="x", pady=(0, 12))
        self._dest_seg.set(_DEST_MAP.get(self._cfg.get("save_to", "drive")))

        # Drive sub-frame
        self._drive_frame = ctk.CTkFrame(body, fg_color="transparent")
        self._folder_var = tk.StringVar(value=self._cfg.get("gdrive_folder_id", ""))
        ctk.CTkLabel(self._drive_frame,
                     text="Folder ID  (leave blank for My Drive root)",
                     font=ctk.CTkFont(size=11), text_color="gray55").pack(anchor="w")
        dr = ctk.CTkFrame(self._drive_frame, fg_color="transparent")
        dr.pack(fill="x", pady=(3, 0))
        ctk.CTkEntry(dr, textvariable=self._folder_var, height=34,
                     placeholder_text="1ABC_folder_id_xyz",
                     font=ctk.CTkFont(size=11)).pack(side="left", fill="x", expand=True)
        ctk.CTkButton(dr, text="?", width=38, height=34,
                      fg_color="transparent", border_width=1,
                      command=self._folder_help).pack(side="left", padx=(6, 0))

        # Local sub-frame
        self._local_frame = ctk.CTkFrame(body, fg_color="transparent")
        self._local_var = tk.StringVar(value=self._cfg.get("local_folder", ""))
        ctk.CTkLabel(self._local_frame, text="Output folder",
                     font=ctk.CTkFont(size=11), text_color="gray55").pack(anchor="w")
        lr = ctk.CTkFrame(self._local_frame, fg_color="transparent")
        lr.pack(fill="x", pady=(3, 0))
        ctk.CTkEntry(lr, textvariable=self._local_var, height=34,
                     placeholder_text="C:\\Videos\\output",
                     font=ctk.CTkFont(size=11)).pack(side="left", fill="x", expand=True)
        ctk.CTkButton(lr, text="Browse", width=82, height=34,
                      command=self._browse_local).pack(side="left", padx=(6, 0))

        self._on_dest_change(self._dest_seg.get())

    def _build_log(self, parent):
        card = ctk.CTkFrame(parent, corner_radius=12)
        card.pack(fill="both", expand=True, padx=16, pady=(0, 10))
        ctk.CTkLabel(card, text="📋  Log",
                     font=ctk.CTkFont(size=12, weight="bold"),
                     anchor="w").pack(fill="x", padx=14, pady=(10, 4))
        ctk.CTkFrame(card, height=1, corner_radius=0,
                     fg_color=("gray75", "gray30")).pack(fill="x", padx=14, pady=(0, 8))
        self._log_box = ctk.CTkTextbox(
            card, height=190, state="disabled",
            font=ctk.CTkFont(family="Consolas", size=10),
            wrap="word", corner_radius=8,
        )
        self._log_box.pack(fill="both", expand=True, padx=10, pady=(0, 10))

    # ── toggles ───────────────────────────────────────────────────────────────

    def _toggle_logo(self):
        s = "normal" if self._logo_sw.get() else "disabled"
        self._logo_ent.configure(state=s)
        self._logo_btn.configure(state=s)

    def _toggle_music(self):
        s = "normal" if self._music_sw.get() else "disabled"
        self._music_ent.configure(state=s)
        self._music_btn.configure(state=s)

    def _on_dest_change(self, value: str):
        if "Drive" in value:
            self._drive_frame.pack(fill="x")
            self._local_frame.pack_forget()
        else:
            self._drive_frame.pack_forget()
            self._local_frame.pack(fill="x")

    # ── file dialogs ──────────────────────────────────────────────────────────

    def _paste(self):
        try:
            self._url_var.set(self.clipboard_get())
        except Exception:
            pass

    def _browse_logo(self):
        p = filedialog.askopenfilename(
            title="Select logo",
            filetypes=[("Image files", "*.png *.jpg *.jpeg *.PNG *.JPG *.JPEG")],
        )
        if p:
            self._logo_var.set(p)

    def _browse_music(self):
        p = filedialog.askopenfilename(
            title="Select music",
            filetypes=[("Audio files", "*.mp3 *.wav *.aac *.m4a *.ogg *.MP3 *.WAV *.AAC")],
        )
        if p:
            self._music_var.set(p)

    def _browse_local(self):
        p = filedialog.askdirectory(title="Select output folder")
        if p:
            self._local_var.set(p)

    def _folder_help(self):
        messagebox.showinfo(
            "Folder ID",
            "Open target folder in Google Drive (browser).\n\n"
            "Copy the ID from the URL:\n"
            "  …/drive/folders/  THIS_PART_IS_THE_ID\n\n"
            "Paste it into the Folder ID field.",
        )

    # ── status & log ─────────────────────────────────────────────────────────

    def _set_status(self, text: str, color: str = "gray55"):
        self.after(0, lambda: self._status_lbl.configure(
            text=f"●  {text}", text_color=color,
        ))

    def _log(self, msg: str):
        def _do():
            self._log_box.configure(state="normal")
            self._log_box.insert("end", msg + "\n")
            self._log_box.see("end")
            self._log_box.configure(state="disabled")
        self.after(0, _do)

    def _clear_log(self):
        self._log_box.configure(state="normal")
        self._log_box.delete("1.0", "end")
        self._log_box.configure(state="disabled")

    # ── progress animation ────────────────────────────────────────────────────

    def _prog_start(self):
        self._anim_running = True
        self._anim_tick()

    def _anim_tick(self):
        if not self._anim_running:
            return
        self._anim_val = (self._anim_val + 0.012) % 1.0
        self._prog.set(self._anim_val)
        self.after(40, self._anim_tick)

    def _prog_stop(self):
        self._anim_running = False
        self._prog.set(0)

    # ── save / deps ───────────────────────────────────────────────────────────

    def _save(self):
        dest_key = _DEST_RMAP.get(self._dest_seg.get(), "drive")
        self._cfg.update({
            "logo_path": self._logo_var.get(),
            "use_logo": bool(self._logo_sw.get()),
            "music_path": self._music_var.get(),
            "use_music": bool(self._music_sw.get()),
            "gdrive_folder_id": self._folder_var.get(),
            "save_to": dest_key,
            "local_folder": self._local_var.get(),
        })
        save_config(self._cfg)
        self._log("Settings saved.")

    def _check_deps(self):
        issues = []
        r = subprocess.run(
            [sys.executable, "-m", "yt_dlp", "--version"],
            capture_output=True, text=True, creationflags=_NO_WINDOW,
        )
        if r.returncode == 0:
            self._log(f"yt-dlp {r.stdout.strip()} ✓")
        else:
            issues.append("• yt-dlp not found  →  pip install yt-dlp")

        r2 = subprocess.run(["ffmpeg", "-version"], capture_output=True, creationflags=_NO_WINDOW)
        if r2.returncode == 0:
            self._log("ffmpeg ✓")
        else:
            issues.append("• ffmpeg not found  →  download from ffmpeg.org, add to PATH")

        if GDRIVE_OK:
            self._log("Google Drive libs ✓")
        else:
            issues.append(
                "• Google Drive libs missing  →\n"
                "  pip install google-api-python-client google-auth-oauthlib"
            )

        if not CREDENTIALS_FILE.exists():
            self._log(f"⚠  credentials.json missing:\n  {CREDENTIALS_FILE}")

        if issues:
            messagebox.showwarning("Missing Dependencies", "\n".join(issues))

    # ── processing ────────────────────────────────────────────────────────────

    def _start(self):
        url = self._url_var.get().strip()
        logo = self._logo_var.get().strip()
        use_logo = bool(self._logo_sw.get())
        use_music = bool(self._music_sw.get())
        music = self._music_var.get().strip()
        dest_key = _DEST_RMAP.get(self._dest_seg.get(), "drive")

        if not url:
            messagebox.showerror("Missing URL", "Paste a Douyin video URL.")
            return
        if use_logo:
            if not logo:
                messagebox.showerror("Missing Logo", "Select a logo file or turn off the Logo switch.")
                return
            if not Path(logo).exists():
                messagebox.showerror("Logo Not Found", f"File not found:\n{logo}")
                return
        if use_music:
            if not music:
                messagebox.showerror("Missing Music", "Select a music file or turn off the Music switch.")
                return
            if not Path(music).exists():
                messagebox.showerror("Music Not Found", f"File not found:\n{music}")
                return
        if dest_key == "local":
            local_dir = self._local_var.get().strip()
            if not local_dir:
                messagebox.showerror("Missing Folder", "Select a local output folder.")
                return
            if not Path(local_dir).is_dir():
                messagebox.showerror("Folder Not Found", f"Folder not found:\n{local_dir}")
                return

        self._run_btn.configure(state="disabled")
        self._prog_start()
        self._set_status("Working...", "#e6a817")
        self._save()

        dest = self._local_var.get().strip() if dest_key == "local" else self._folder_var.get().strip()
        threading.Thread(
            target=self._worker,
            args=(url, logo, use_logo, music, use_music, dest_key, dest),
            daemon=True,
        ).start()

    def _worker(self, url: str, logo: str, use_logo: bool,
                music: str, use_music: bool, mode: str, dest: str):
        tmp = tempfile.mkdtemp(prefix="reup_")
        try:
            self._set_status("Downloading...", "#e6a817")
            video = download_video(url, tmp, self._log)

            if use_logo or use_music:
                self._set_status("Processing video...", "#e6a817")
                out = str(Path(tmp) / "output.mp4")
                process_video(
                    video, out, self._log,
                    logo=logo if use_logo else None,
                    music=music if use_music else None,
                )
            else:
                out = video
                self._log("⊘ No processing (logo + music both off)")

            if mode == "local":
                self._set_status("Saving...", "#e6a817")
                final = str(Path(dest) / "output.mp4")
                shutil.copy2(out, final)
                self._log(f"✓ Saved: {final}")
                self._set_status("Done!", "#3dba6f")
                self.after(0, lambda: messagebox.showinfo("Done!", f"Video saved to:\n{final}"))
            else:
                self._set_status("Uploading...", "#e6a817")
                link = upload_gdrive(out, dest, self._log)
                self._set_status("Done!", "#3dba6f")
                self.after(0, lambda: messagebox.showinfo("Done!", f"Video uploaded!\n\n{link}"))

        except Exception as exc:
            self._log(f"✗ ERROR: {exc}")
            err = str(exc)
            self._set_status("Error", "#e05252")
            self.after(0, lambda: messagebox.showerror("Error", err))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
            self.after(0, self._prog_stop)
            self.after(0, lambda: self._run_btn.configure(state="normal"))


if __name__ == "__main__":
    app = App()
    app.mainloop()
