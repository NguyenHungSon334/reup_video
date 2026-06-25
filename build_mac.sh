#!/bin/bash
# Build Reup Video .dmg for macOS
# Run this script on a Mac: bash build_mac.sh

set -e
echo "================================================"
echo " Reup Video | Build macOS DMG"
echo "================================================"

# 1. Dependencies
echo "[1/5] Installing dependencies..."
pip3 install pyinstaller pillow --quiet
pip3 install -r requirements.txt --quiet

# 2. Generate .icns icon
echo "[2/5] Generating icon..."
python3 assets/generate_icon_mac.py

# 3. Flutter web build
echo "[3/5] Checking Flutter web build..."
if [ ! -f "flutter_ui/build/web/index.html" ]; then
    echo "  Building Flutter web..."
    cd flutter_ui && flutter build web --release && cd ..
fi

# 4. PyInstaller
echo "[4/5] Building .app with PyInstaller..."
rm -rf dist/ReupVideo.app build
pyinstaller reup_mac.spec --noconfirm --clean

# 5. Create DMG
echo "[5/5] Creating DMG..."
mkdir -p dist/installer_mac

if command -v create-dmg &> /dev/null; then
    create-dmg \
        --volname "Reup Video" \
        --volicon "assets/icon.icns" \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "ReupVideo.app" 175 190 \
        --hide-extension "ReupVideo.app" \
        --app-drop-link 425 190 \
        "dist/installer_mac/ReupVideo_1.0.0.dmg" \
        "dist/ReupVideo.app"
else
    # Fallback: simple DMG via hdiutil
    hdiutil create -volname "Reup Video" \
        -srcfolder "dist/ReupVideo.app" \
        -ov -format UDZO \
        "dist/installer_mac/ReupVideo_1.0.0.dmg"
fi

echo ""
echo "================================================"
echo " DONE! dist/installer_mac/ReupVideo_1.0.0.dmg"
echo "================================================"
