#!/bin/bash
# Removes StockPilot (installed with install.sh). Your data is kept unless you say yes.
pkill -x stockpilot 2>/dev/null || true
rm -rf "$HOME/.local/share/StockPilot"
rm -f "$HOME/.local/bin/stockpilot" "$HOME/.local/share/applications/stockpilot.desktop" "$HOME/.local/share/icons/hicolor/256x256/apps/stockpilot.png" "$HOME/.config/autostart/stockpilot.desktop"
read -r -p "Also delete your StockPilot data? (y/N) " a
if [[ "$a" =~ ^[Yy] ]]; then rm -rf "$HOME/.config/StockPilot"; echo "Data deleted."; fi
echo "StockPilot is uninstalled."
