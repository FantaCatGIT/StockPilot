#!/usr/bin/env bash
# Builds StockPilot for Linux x64:
#   StockPilot-<ver>-linux-x64.tar.xz   any distro / Steam Deck: unpack, run ./install.sh (no root needed)
#   stockpilot_<ver>_amd64.deb          Ubuntu / Debian / Mint / Pop!_OS: double-click to install
# Needs python3, tar, dpkg-deb and the Electron Linux zip:  ELECTRON_LINUX_X64=electron-v38.2.2-linux-x64.zip ./build/make-linux.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(python3 -c "import json;print(json.load(open('$ROOT/package.json'))['version'])")"
OUT="$ROOT/dist"; W="$OUT/linux"; rm -rf "$W"; mkdir -p "$W"
: "${ELECTRON_LINUX_X64:?}"

# the app folder (same for both packages)
A="$W/StockPilot"; mkdir -p "$A"
unzip -q "$ELECTRON_LINUX_X64" -d "$A"
mv "$A/electron" "$A/stockpilot"; rm -f "$A/resources/default_app.asar"
mkdir -p "$A/resources/app/build"
cp -r "$ROOT/main.js" "$ROOT/preload.js" "$ROOT/package.json" "$ROOT/backend" "$ROOT/ui" "$A/resources/app/"
cp "$ROOT/build/icon.png" "$A/resources/app/build/"; cp "$ROOT/build/icon.png" "$A/stockpilot.png"
# smaller download: English only, no software-GPU fallback
( cd "$A/locales" && ls | grep -v -x -e en-US.pak -e en-GB.pak | xargs rm -f )
rm -f "$A/libvk_swiftshader.so" "$A/vk_swiftshader_icd.json" "$A/libvulkan.so.1"

# 1) portable tar.xz with a per-user installer
T="$W/tar/StockPilot-$VERSION-linux-x64"; mkdir -p "$T"
cp -a "$A" "$T/StockPilot"
cp "$ROOT/build/linux/install.sh" "$ROOT/build/linux/uninstall.sh" "$ROOT/build/linux/README.txt" "$T/"
chmod +x "$T/install.sh" "$T/uninstall.sh" "$T/StockPilot/stockpilot"
tar -C "$W/tar" -cf - "StockPilot-$VERSION-linux-x64" | xz -9 > "$OUT/StockPilot-$VERSION-linux-x64.tar.xz"
echo "Built: $OUT/StockPilot-$VERSION-linux-x64.tar.xz"

# 2) .deb
D="$W/deb"; mkdir -p "$D/DEBIAN" "$D/opt" "$D/usr/bin" "$D/usr/share/applications" "$D/usr/share/icons/hicolor/256x256/apps"
cp -a "$A" "$D/opt/StockPilot"
ln -s /opt/StockPilot/stockpilot "$D/usr/bin/stockpilot"
cp "$ROOT/build/icon.png" "$D/usr/share/icons/hicolor/256x256/apps/stockpilot.png"
cat > "$D/usr/share/applications/stockpilot.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=StockPilot
Comment=Charts, trading, auto actions and skins for Screen Stocks
Exec=/opt/StockPilot/stockpilot %U
Icon=stockpilot
Terminal=false
Categories=Game;Utility;
StartupWMClass=StockPilot
EOF
SIZE=$(du -sk "$D/opt" | cut -f1)
cat > "$D/DEBIAN/control" <<EOF
Package: stockpilot
Version: $VERSION
Section: games
Priority: optional
Architecture: amd64
Installed-Size: $SIZE
Depends: libgtk-3-0 | libgtk-3-0t64, libnss3, libxss1, libxtst6, libgbm1, libasound2 | libasound2t64, libnotify4, xdg-utils
Maintainer: StockPilot <stockpilot@users.noreply.github.com>
Description: StockPilot - a mod app for the game Screen Stocks
 Live charts, one-click trading, portfolio, dividends, journal, statistics,
 news, auto actions, an experimental bot and custom skins for Screen Stocks.
EOF
cat > "$D/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
# Chromium's sandbox helper must be setuid root
chown root:root /opt/StockPilot/chrome-sandbox 2>/dev/null || true
chmod 4755 /opt/StockPilot/chrome-sandbox 2>/dev/null || true
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q /usr/share/applications || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q /usr/share/icons/hicolor || true
exit 0
EOF
chmod 755 "$D/DEBIAN/postinst"
dpkg-deb --root-owner-group -Zxz --build "$D" "$OUT/stockpilot_${VERSION}_amd64.deb" >/dev/null
echo "Built: $OUT/stockpilot_${VERSION}_amd64.deb"
