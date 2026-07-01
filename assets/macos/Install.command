#!/bin/bash
# One-click installer: copies the app to /Applications and strips the macOS
# quarantine flag so it opens without the "is damaged / can't be opened" error.
# The app is unsigned (no paid Apple cert), so this replaces drag-to-Applications.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/Hồn Đá Reup.app"
DEST="/Applications/Hồn Đá Reup.app"

echo "Installing Hồn Đá Reup to /Applications..."
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

echo "Removing quarantine flag..."
xattr -cr "$DEST"

echo "Launching Hồn Đá Reup..."
open "$DEST"

echo "Done! Hồn Đá Reup is installed in your Applications folder."
