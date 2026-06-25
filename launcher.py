"""
Reup Video — desktop launcher (single EXE).
- First run: shows progress window while installing Playwright Chromium
- Subsequent runs: instant start + auto-open browser
"""
import sys
import os

if getattr(sys, 'frozen', False):
    sys.path.insert(0, sys._MEIPASS)
    # console=False sets stdout/stderr to None — redirect to log file
    _LOG_DIR = os.path.join(os.environ.get("APPDATA", os.path.expanduser("~")), "ReupVideo")
    os.makedirs(_LOG_DIR, exist_ok=True)
    _log_file = open(os.path.join(_LOG_DIR, "app.log"), "w", encoding="utf-8", buffering=1)
    sys.stdout = _log_file
    sys.stderr = _log_file

# Store Playwright browsers in AppData — persists across runs
_BROWSERS_DIR = os.path.join(
    os.environ.get("APPDATA", os.path.expanduser("~")),
    "ReupVideo", "browsers",
)
os.makedirs(_BROWSERS_DIR, exist_ok=True)
os.environ["PLAYWRIGHT_BROWSERS_PATH"] = _BROWSERS_DIR

import socket
import subprocess
import threading
import time
import webbrowser
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
        self.root.protocol("WM_DELETE_WINDOW", lambda: None)  # disable close
        self.root.attributes("-topmost", True)

        # Center on screen
        self.root.update_idletasks()
        sw, sh = self.root.winfo_screenwidth(), self.root.winfo_screenheight()
        self.root.geometry(f"480x200+{(sw-480)//2}+{(sh-200)//2}")

        tk.Label(self.root, text="🎬  Reup Video",
                 font=("Segoe UI", 18, "bold"),
                 fg="#ffffff", bg="#0d1117").pack(pady=(28, 6))

        tk.Label(self.root, text="Thiết lập lần đầu — chỉ cần làm 1 lần",
                 font=("Segoe UI", 10),
                 fg="#6e7681", bg="#0d1117").pack()

        self._status_var = tk.StringVar(value="Đang kiểm tra...")
        tk.Label(self.root, textvariable=self._status_var,
                 font=("Segoe UI", 9),
                 fg="#58a6ff", bg="#0d1117").pack(pady=(8, 10))

        style = ttk.Style()
        style.theme_use("clam")
        style.configure("Blue.Horizontal.TProgressbar",
                        troughcolor="#161b22",
                        background="#1f6feb",
                        borderwidth=0, relief="flat",
                        thickness=5)

        self._bar = ttk.Progressbar(self.root,
                                     style="Blue.Horizontal.TProgressbar",
                                     mode="indeterminate", length=420)
        self._bar.pack()
        self._bar.start(10)
        self.root.update()

    def set_status(self, text: str):
        self._status_var.set(text)
        self.root.update()

    def close(self):
        self._bar.stop()
        self.root.destroy()

    def tick(self):
        self.root.update()


# ── Playwright check / install ─────────────────────────────────────────────

def _playwright_ready() -> bool:
    try:
        from playwright.sync_api import sync_playwright
        with sync_playwright() as p:
            return os.path.exists(p.chromium.executable_path)
    except Exception:
        return False


def _install_playwright(ui: _SetupWindow):
    ui.set_status("Đang tải Playwright Chromium (~150 MB)...")
    subprocess.run(
        [sys.executable, "-m", "playwright", "install", "chromium"],
        check=False,
    )
    ui.set_status("Hoàn tất! Đang khởi động...")


# ── Helpers ────────────────────────────────────────────────────────────────

def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("", 0))
        return s.getsockname()[1]


# ── Main ───────────────────────────────────────────────────────────────────

def main():
    if not _playwright_ready():
        ui = _SetupWindow()
        worker = threading.Thread(target=_install_playwright, args=(ui,), daemon=True)
        worker.start()
        while worker.is_alive():
            ui.tick()
            time.sleep(0.05)
        ui.close()

    port = _free_port()
    os.environ["PORT"] = str(port)

    threading.Thread(
        target=lambda: (time.sleep(2.5), webbrowser.open(f"http://127.0.0.1:{port}")),
        daemon=True,
    ).start()

    import uvicorn
    uvicorn.run("backend.main:app", host="127.0.0.1", port=port,
                reload=False, log_config=None)


if __name__ == "__main__":
    main()
