#!/bin/bash
# Removes StockPilot. Your data (price history, journal, auto actions) is kept unless you say yes below.
echo "Uninstalling StockPilot..."
osascript -e 'quit app "StockPilot"' >/dev/null 2>&1; sleep 1
osascript -e 'tell application "System Events" to delete login item "StockPilot"' >/dev/null 2>&1
rm -rf "/Applications/StockPilot.app" "$HOME/Applications/StockPilot.app"
read -r -p "Also delete your StockPilot data? (y/N) " a
if [[ "$a" =~ ^[Yy] ]]; then rm -rf "$HOME/Library/Application Support/StockPilot"; echo "Data deleted."; fi
echo "StockPilot is uninstalled. You can close this window."
