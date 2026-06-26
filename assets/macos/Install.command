#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="/Applications/Reup Video.app"

echo "Installing Reup Video..."
rm -rf "$DEST"
cp -r "$SCRIPT_DIR/Reup Video.app" "$DEST"

echo "Removing quarantine..."
xattr -cr "$DEST"

echo "Opening Reup Video..."
open "$DEST"

echo "Done!"
