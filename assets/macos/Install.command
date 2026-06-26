#!/bin/bash
DEST="/Applications/Reup Video.app"

echo "Fixing quarantine on Reup Video..."
xattr -cr "$DEST"

echo "Opening Reup Video..."
open "$DEST"

echo "Done!"
