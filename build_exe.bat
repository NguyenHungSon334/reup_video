@echo off
title Reup Video — Build
color 0A
echo.
echo  ==========================================
echo   Reup Video  ^|  Build Desktop App
echo  ==========================================
echo.

:: ── Step 1: Python dependencies ─────────────────────────────────────────
echo [1/5] Installing Python dependencies...
pip install pyinstaller pillow --quiet
pip install -r requirements.txt --quiet
if errorlevel 1 ( echo  ERROR: pip failed & pause & exit /b 1 )
echo  OK

:: ── Step 2: Generate icon ───────────────────────────────────────────────
echo [2/5] Generating icon...
python assets\generate_icon.py
echo  OK

:: ── Step 3: Flutter Windows desktop build ───────────────────────────────
echo [3/5] Building Flutter Windows desktop...
cd flutter_ui
flutter build windows --release
if errorlevel 1 ( echo  ERROR: flutter build failed & cd .. & pause & exit /b 1 )
cd ..
echo  OK

:: ── Step 4: PyInstaller backend ─────────────────────────────────────────
echo [4/5] Building backend EXE...
if exist dist\ReupVideo.exe del /f /q dist\ReupVideo.exe
if exist build rmdir /s /q build
pyinstaller reup.spec --noconfirm --clean
if errorlevel 1 ( echo  ERROR: PyInstaller failed & pause & exit /b 1 )
echo  OK

:: Copy Flutter exe next to backend exe so they can find each other
copy "flutter_ui\build\windows\x64\runner\Release\reup_flutter.exe" "dist\reup_flutter.exe" >nul 2>&1

:: ── Step 5: Inno Setup installer ────────────────────────────────────────
echo [5/5] Building installer...
set ISCC=
for %%p in (
    "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
    "C:\Program Files\Inno Setup 6\ISCC.exe"
) do ( if exist %%p set ISCC=%%p )

if defined ISCC (
    if not exist dist\installer mkdir dist\installer
    %ISCC% setup.iss
    echo  OK
    echo.
    echo  ==========================================
    echo   DONE!
    echo   Installer: dist\installer\Setup_ReupVideo_1.0.0.exe
    echo  ==========================================
) else (
    echo  Inno Setup not found. Download: https://jrsoftware.org/isinfo.php
    echo.
    echo  ==========================================
    echo   DONE (no installer)
    echo   Backend : dist\ReupVideo.exe
    echo   Flutter : flutter_ui\build\windows\x64\runner\Release\
    echo  ==========================================
)
echo.
pause
