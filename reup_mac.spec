# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec — Reup Video macOS .app bundle."""

import os
from PyInstaller.utils.hooks import collect_all, collect_data_files, collect_submodules

block_cipher = None

pw_datas, pw_binaries, pw_hiddenimports = collect_all("playwright")
ff_datas = collect_data_files("imageio_ffmpeg")
yt_datas, yt_binaries, yt_hiddenimports = collect_all("yt_dlp")

icon_path = os.path.join(os.getcwd(), "assets", "icon.icns")

a = Analysis(
    ["launcher.py"],
    pathex=[os.getcwd()],
    binaries=[*pw_binaries, *yt_binaries],
    datas=[
        ("backend", "backend"),
        *pw_datas,
        *ff_datas,
        *yt_datas,
    ],
    hiddenimports=[
        "uvicorn", "uvicorn.main", "uvicorn.config", "uvicorn.logging",
        "uvicorn.loops", "uvicorn.loops.asyncio", "uvicorn.loops.uvloop",
        "uvicorn.lifespan", "uvicorn.lifespan.off", "uvicorn.lifespan.on",
        "uvicorn.protocols", "uvicorn.protocols.http", "uvicorn.protocols.http.auto",
        "uvicorn.protocols.http.h11_impl", "uvicorn.protocols.http.httptools_impl",
        "uvicorn.protocols.websockets", "uvicorn.protocols.websockets.auto",
        "uvicorn.protocols.websockets.websockets_impl",
        "uvicorn.protocols.websockets.wsproto_impl",
        "uvicorn.middleware", "uvicorn.middleware.message_loggers",
        "uvicorn.middleware.proxy_headers", "uvicorn.supervisors",
        "fastapi", "fastapi.staticfiles", "fastapi.middleware.cors",
        "starlette", "starlette.staticfiles", "starlette.middleware",
        "starlette.middleware.cors", "starlette.websockets",
        "anyio", "anyio._backends._asyncio", "anyio._backends._trio",
        "h11", "httpx", "httpcore",
        "multipart", "python_multipart",
        "websockets", "websockets.legacy", "websockets.legacy.server",
        "aiofiles", "dotenv", "python_dotenv",
        "google.auth", "google.auth.transport", "google.auth.transport.requests",
        "googleapiclient", "googleapiclient.discovery", "googleapiclient.http",
        "google_auth_oauthlib", "google_auth_oauthlib.flow",
        "imageio_ffmpeg", "tkinter", "tkinter.ttk",
        *pw_hiddenimports,
        *yt_hiddenimports,
        *collect_submodules("backend"),
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=["matplotlib", "numpy", "PIL", "cv2", "scipy"],
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="ReupVideo",
    debug=False,
    strip=False,
    upx=True,
    console=False,
    icon=icon_path if os.path.exists(icon_path) else None,
)

app = BUNDLE(
    coll := COLLECT(
        exe,
        a.binaries,
        a.zipfiles,
        a.datas,
        strip=False,
        upx=True,
        upx_exclude=["playwright", "node", "chromium", "chrome"],
        name="ReupVideo",
    ),
    name="ReupVideo.app",
    icon=icon_path if os.path.exists(icon_path) else None,
    bundle_identifier="com.reupvideo.app",
    info_plist={
        "CFBundleName": "Reup Video",
        "CFBundleDisplayName": "Reup Video",
        "CFBundleVersion": "2.1.19",
        "CFBundleShortVersionString": "2.1.19",
        "NSHighResolutionCapable": True,
        "LSMinimumSystemVersion": "10.15",
    },
)
