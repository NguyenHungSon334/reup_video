"""
Reup Video — backend launcher.
Starts FastAPI on port 8765, then launches the Flutter desktop UI.
When Flutter closes, the backend shuts down automatically.
"""
import sys
import os
import signal

if getattr(sys, 'frozen', False):
    sys.path.insert(0, sys._MEIPASS)
    _EXE_DIR = os.path.dirname(sys.executable)
    if sys.platform == "darwin":
        _LOG_DIR = os.path.join(os.path.expanduser("~/Library/Application Support"), "ReupVideo")
        # macOS COLLECT mode: pw_browsers sits next to the executable
        os.environ["PLAYWRIGHT_BROWSERS_PATH"] = os.path.join(_EXE_DIR, "pw_browsers")
    else:
        _LOG_DIR = os.path.join(os.environ.get("APPDATA", os.path.expanduser("~")), "ReupVideo")
        # Windows single-file: pw_browsers extracted into _MEIPASS
        os.environ["PLAYWRIGHT_BROWSERS_PATH"] = os.path.join(sys._MEIPASS, "pw_browsers")
    os.makedirs(_LOG_DIR, exist_ok=True)
    _log = open(os.path.join(_LOG_DIR, "backend.log"), "w", encoding="utf-8", buffering=1)
    sys.stdout = _log
    sys.stderr = _log
else:
    _EXE_DIR = os.path.dirname(os.path.abspath(__file__))
    os.environ.setdefault(
        "PLAYWRIGHT_BROWSERS_PATH",
        os.path.join(os.environ.get("APPDATA", os.path.expanduser("~")), "ReupVideo", "browsers"),
    )

BACKEND_PORT = 8765

import socket
import subprocess
import threading
import time


def _backend_ready(timeout: int = 60) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", BACKEND_PORT), timeout=1):
                return True
        except OSError:
            time.sleep(0.5)
    return False


def _launch_flutter() -> "subprocess.Popen | None":
    candidates = [
        # macOS .app bundle — Flutter builds produce .app, not a plain binary
        os.path.join(_EXE_DIR, "reup_flutter.app", "Contents", "MacOS", "reup_flutter"),
        os.path.join(_EXE_DIR, "reup_flutter.exe"),
        os.path.join(_EXE_DIR, "ReupVideo_UI.exe"),
        os.path.join(_EXE_DIR, "reup_flutter"),
        os.path.join(_EXE_DIR, "ReupVideo_UI"),
    ]
    for path in candidates:
        if os.path.exists(path):
            return subprocess.Popen([path])
    # Dev fallback
    flutter_dir = os.path.join(os.path.dirname(_EXE_DIR), "flutter_ui")
    if os.path.isdir(flutter_dir):
        device = "macos" if sys.platform == "darwin" else "windows"
        return subprocess.Popen(["flutter", "run", f"-d{device}"], cwd=flutter_dir)
    return None


def _wait_then_launch():
    if not _backend_ready():
        return
    proc = _launch_flutter()
    if proc:
        proc.wait()  # block until Flutter window closes
        # Flutter exited — kill the backend (uvicorn in main thread)
        os.kill(os.getpid(), signal.SIGTERM)


def main():
    threading.Thread(target=_wait_then_launch, daemon=True).start()

    os.environ["PORT"] = str(BACKEND_PORT)
    import uvicorn
    uvicorn.run("backend.main:app", host="127.0.0.1", port=BACKEND_PORT,
                reload=False, log_config=None)


if __name__ == "__main__":
    import multiprocessing
    multiprocessing.freeze_support()
    main()
