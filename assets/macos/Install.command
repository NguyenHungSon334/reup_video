#!/bin/bash
# One-click installer: copies the app to /Applications and strips the macOS
# quarantine flag so it opens without the "is damaged / can't be opened" error.
# The app is unsigned (no paid Apple cert), so this replaces drag-to-Applications.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/Reup Video.app"
DEST="/Applications/Reup Video.app"

echo "Installing Reup Video to /Applications..."
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

echo "Removing quarantine flag..."
xattr -cr "$DEST"

echo "Launching Reup Video..."
open "$DEST"

echo "Done! Reup Video is installed in your Applications folder."
