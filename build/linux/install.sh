#!/bin/bash
# Installs StockPilot for your user (no root): ~/.local/share/StockPilot + app menu entry.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.local/share/StockPilot"
pkill -x stockpilot 2>/dev/null || true
rm -rf "$DEST"; mkdir -p "$DEST"; cp -a "$HERE/StockPilot/." "$DEST/"
mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications" "$HOME/.local/share/icons/hicolor/256x256/apps"
# launcher: Chromium's sandbox helper can't be setuid in a home folder, so run without it
cat > "$HOME/.local/bin/stockpilot" <<LAUNCH
#!/bin/sh
export STOCKPILOT_LAUNCHER="\$HOME/.local/bin/stockpilot"
exec "$DEST/stockpilot" --no-sandbox "\$@"
LAUNCH
chmod +x "$HOME/.local/bin/stockpilot" "$DEST/stockpilot"
cp "$DEST/stockpilot.png" "$HOME/.local/share/icons/hicolor/256x256/apps/stockpilot.png"
cat > "$HOME/.local/share/applications/stockpilot.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=StockPilot
Comment=Charts, trading, auto actions and skins for Screen Stocks
Exec=$HOME/.local/bin/stockpilot %U
Icon=stockpilot
Terminal=false
Categories=Game;Utility;
StartupWMClass=StockPilot
DESK
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q "$HOME/.local/share/applications" || true
echo "StockPilot is installed - find it in your app menu (or run: ~/.local/bin/stockpilot)."
nohup "$HOME/.local/bin/stockpilot" >/dev/null 2>&1 &
