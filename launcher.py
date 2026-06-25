"""
Reup Video — backend launcher.
Starts FastAPI on port 8765, then launches the Flutter desktop UI exe.
On first run, installs Playwright Chromium with a progress window.
"""
import sys
import os

if getattr(sys, 'frozen', False):
    sys.path.insert(0, sys._MEIPASS)
    _EXE_DIR = os.path.dirname(sys.executable)
    _LOG_DIR = os.path.join(os.environ.get("APPDATA", os.path.expanduser("~")), "ReupVideo")
    os.makedirs(_LOG_DIR, exist_ok=True)
    _log = open(os.path.join(_LOG_DIR, "backend.log"), "w", encoding="utf-8", buffering=1)
    sys.stdout = _log
    sys.stderr = _log
else:
    _EXE_DIR = os.path.dirname(os.path.abspath(__file__))

_BROWSERS_DIR = os.path.join(
    os.environ.get("APPDATA", os.path.expanduser("~")),
    "ReupVideo", "browsers",
)
os.makedirs(_BROWSERS_DIR, exist_ok=True)
os.environ["PLAYWRIGHT_BROWSERS_PATH"] = _BROWSERS_DIR

BACKEND_PORT = 8765

import socket
import subprocess
import threading
import time
import tkinter as tk
from tkinter import ttk


# ── First-run setup window ─────────────────────────────────────────────────

class _SetupWindow:
    def __init__(self):
        self.root = tk.Tk()
        self.root.title("Reup Video")
        self.root.geometry("480x200")
        self.root.resizable(False, False)
        self.root.configure(bg="#0d1117")
        self.root.protocol("WM_DELETE_WINDOW", lambda: None)
        self.root.attributes("-topmost", True)

        sw, sh = self.root.winfo_screenwidth(), self.root.winfo_screenheight()
        self.root.geometry(f"480x200+{(sw-480)//2}+{(sh-200)//2}")

        tk.Label(self.root, text="🎬  Reup Video",
                 font=("Segoe UI", 18, "bold"),
                 fg="#ffffff", bg="#0d1117").pack(pady=(28, 6))

        tk.Label(self.root, text="Thiết lập lần đầu — chỉ cần làm 1 lần",
                 font=("Segoe UI", 10), fg="#6e7681", bg="#0d1117").pack()

        self._status = tk.StringVar(value="Đang kiểm tra...")
        tk.Label(self.root, textvariable=self._status,
                 font=("Segoe UI", 9), fg="#58a6ff", bg="#0d1117").pack(pady=(8, 10))

        s = ttk.Style()
        s.theme_use("clam")
        s.configure("B.Horizontal.TProgressbar",
                    troughcolor="#161b22", background="#1f6feb",
                    borderwidth=0, relief="flat", thickness=5)

        self._bar = ttk.Progressbar(self.root, style="B.Horizontal.TProgressbar",
                                     mode="indeterminate", length=420)
        self._bar.pack()
        self._bar.start(10)
        self.root.update()

    def status(self, text: str):
        self._status.set(text)
        self.root.update()

    def close(self):
        self._bar.stop()
        self.root.destroy()

    def tick(self):
        self.root.update()


# ── Playwright ─────────────────────────────────────────────────────────────

def _playwright_ready() -> bool:
    try:
        from playwright.sync_api import sync_playwright
        with sync_playwright() as p:
            return os.path.exists(p.chromium.executable_path)
    except Exception:
        return False


def _install_playwright(ui: _SetupWindow):
    ui.status("Đang tải Playwright Chromium (~150 MB)...")
    subprocess.run([sys.executable, "-m", "playwright", "install", "chromium"], check=False)
    ui.status("Hoàn tất! Đang khởi động...")


# ── Flutter UI launcher ────────────────────────────────────────────────────

def _backend_ready(timeout: int = 60) -> bool:
    """Poll until the backend TCP port accepts connections."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", BACKEND_PORT), timeout=1):
                return True
        except OSError:
            time.sleep(0.5)
    return False


def _wait_then_launch():
    if _backend_ready():
        _launch_flutter()


def _launch_flutter():
    """Find and launch the Flutter desktop exe sitting next to this backend."""
    candidates = [
        os.path.join(_EXE_DIR, "reup_flutter.exe"),       # Windows
        os.path.join(_EXE_DIR, "ReupVideo_UI.exe"),
        os.path.join(_EXE_DIR, "reup_flutter"),            # macOS/Linux
        os.path.join(_EXE_DIR, "ReupVideo_UI"),
    ]
    for path in candidates:
        if os.path.exists(path):
            subprocess.Popen([path])
            return
    # Dev mode fallback — run flutter from source
    flutter_dir = os.path.join(os.path.dirname(_EXE_DIR), "flutter_ui")
    if os.path.isdir(flutter_dir):
        subprocess.Popen(["flutter", "run", "-d", "windows"], cwd=flutter_dir)


# ── Main ───────────────────────────────────────────────────────────────────

def main():
    # First-run: install playwright with progress UI
    if not _playwright_ready():
        ui = _SetupWindow()
        worker = threading.Thread(target=_install_playwright, args=(ui,), daemon=True)
        worker.start()
        while worker.is_alive():
            ui.tick()
            time.sleep(0.05)
        ui.close()

    # Launch Flutter UI only after backend is actually ready
    threading.Thread(target=_wait_then_launch, daemon=True).start()

    os.environ["PORT"] = str(BACKEND_PORT)
    import uvicorn
    uvicorn.run("backend.main:app", host="127.0.0.1", port=BACKEND_PORT,
                reload=False, log_config=None)


if __name__ == "__main__":
    main()
