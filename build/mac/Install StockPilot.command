#!/bin/bash
# Copies StockPilot into Applications and lets macOS open it (it isn't from the App Store).
cd "$(dirname "$0")" || exit 1
echo "Installing StockPilot..."
osascript -e 'quit app "StockPilot"' >/dev/null 2>&1; sleep 1
DEST="/Applications"
if ! ( rm -rf "$DEST/StockPilot.app" && cp -R "StockPilot.app" "$DEST/" ) 2>/dev/null; then
  DEST="$HOME/Applications"; mkdir -p "$DEST"; rm -rf "$DEST/StockPilot.app"; cp -R "StockPilot.app" "$DEST/" || { echo "Could not copy StockPilot."; exit 1; }
fi
xattr -cr "$DEST/StockPilot.app"
open "$DEST/StockPilot.app"
echo ""
echo "Done! StockPilot is in $DEST (and in Launchpad). You can close this window."
