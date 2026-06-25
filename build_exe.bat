@echo off
title Reup Video — Build
color 0A
echo.
echo  ==========================================
echo   Reup Video  ^|  Build Professional EXE
echo  ==========================================
echo.

:: ── Step 1: Dependencies ────────────────────────────────────────────────
echo [1/5] Installing dependencies...
pip install pyinstaller pillow --quiet
pip install -r requirements.txt --quiet
if errorlevel 1 ( echo  ERROR: pip failed & pause & exit /b 1 )
echo  OK

:: ── Step 2: Generate icon ───────────────────────────────────────────────
echo [2/5] Generating icon...
python assets\generate_icon.py
if errorlevel 1 ( echo  WARNING: icon generation failed, continuing without icon )
echo  OK

:: ── Step 3: Flutter web build check ─────────────────────────────────────
echo [3/5] Checking Flutter web build...
if not exist "flutter_ui\build\web\index.html" (
    echo  Building Flutter web...
    cd flutter_ui
    flutter build web --release
    cd ..
)
echo  OK

:: ── Step 4: PyInstaller ─────────────────────────────────────────────────
echo [4/5] Building EXE with PyInstaller (3-5 minutes)...
if exist dist\ReupVideo.exe del /f /q dist\ReupVideo.exe
if exist build rmdir /s /q build
pyinstaller reup.spec --noconfirm --clean
if errorlevel 1 ( echo  ERROR: PyInstaller failed & pause & exit /b 1 )
echo  OK

:: ── Step 5: Inno Setup installer ────────────────────────────────────────
echo [5/5] Building installer with Inno Setup...
set ISCC=
for %%p in (
    "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
    "C:\Program Files\Inno Setup 6\ISCC.exe"
) do (
    if exist %%p set ISCC=%%p
)

if defined ISCC (
    if not exist "dist\installer" mkdir "dist\installer"
    %ISCC% setup.iss
    echo  OK
    echo.
    echo  ==========================================
    echo   DONE!
    echo.
    echo   Single EXE  :  dist\ReupVideo.exe
    echo   Installer   :  dist\installer\Setup_ReupVideo_1.0.0.exe
    echo  ==========================================
) else (
    echo  Inno Setup not found — skipping installer.
    echo  Download: https://jrsoftware.org/isinfo.php
    echo.
    echo  ==========================================
    echo   DONE!
    echo.
    echo   Single EXE  :  dist\ReupVideo.exe
    echo  ==========================================
)
echo.
pause
