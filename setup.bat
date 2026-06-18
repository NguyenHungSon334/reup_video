@echo off
echo Installing Python dependencies...
pip install -r requirements.txt
echo.
echo Done! Now:
echo   1. Place credentials.json in this folder (from Google Cloud Console)
echo   2. Run: python reup.py
pause
