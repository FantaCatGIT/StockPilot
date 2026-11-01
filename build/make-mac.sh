#!/usr/bin/env bash
# Builds StockPilot-<version>-macOS.dmg (Apple Silicon) with StockPilot.app + install / uninstall helpers.
# Runs on Linux or macOS. Needs python3 and the Electron macOS arm64 zip:
#   ELECTRON_MAC_ARM64=electron-v38.2.2-darwin-arm64.zip ./build/make-mac.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(python3 -c "import json;print(json.load(open('$ROOT/package.json'))['version'])")"
OUT="$ROOT/dist"; mkdir -p "$OUT"
: "${ELECTRON_MAC_ARM64:?}"

build() { # $1 = zip, $2 = label for the file name
  local W="$OUT/mac-$2"; rm -rf "$W"; mkdir -p "$W/StockPilot"
  unzip -q "$1" -d "$W/e"
  mv "$W/e/Electron.app" "$W/StockPilot/StockPilot.app"
  local C="$W/StockPilot/StockPilot.app/Contents"
  mv "$C/MacOS/Electron" "$C/MacOS/StockPilot"
  rm -f "$C/Resources/default_app.asar" "$C/Resources/electron.icns"
  cp "$ROOT/logo/logo.icns" "$C/Resources/stockpilot.icns"
  mkdir -p "$C/Resources/app/build"
  cp -r "$ROOT/main.js" "$ROOT/preload.js" "$ROOT/package.json" "$ROOT/backend" "$ROOT/ui" "$C/Resources/app/"
  cp "$ROOT/build/icon.png" "$C/Resources/app/build/"
  python3 - "$C/Info.plist" "$VERSION" <<'PY'
import plistlib, sys
f, ver = sys.argv[1], sys.argv[2]
p = plistlib.load(open(f, 'rb'))
p.update({'CFBundleName': 'StockPilot', 'CFBundleDisplayName': 'StockPilot', 'CFBundleExecutable': 'StockPilot',
          'CFBundleIconFile': 'stockpilot.icns', 'CFBundleIdentifier': 'com.stockpilot.app',
          'CFBundleShortVersionString': ver, 'CFBundleVersion': ver,
          'LSApplicationCategoryType': 'public.app-category.finance',
          'NSHumanReadableCopyright': 'MIT License - fan-made mod for Screen Stocks'})
for k in ['ElectronAsarIntegrity', 'NSBluetoothAlwaysUsageDescription', 'NSBluetoothPeripheralUsageDescription', 'NSCameraUsageDescription', 'NSMicrophoneUsageDescription']:
    p.pop(k, None)
plistlib.dump(p, open(f, 'wb'))
PY
  cp "$ROOT/build/mac/Install StockPilot.command" "$ROOT/build/mac/Uninstall StockPilot.command" "$ROOT/build/mac/READ ME.txt" "$W/StockPilot/"
  chmod +x "$W/StockPilot/"*.command
  rm -rf "$W/e"
  # smaller download: English only, no software-GPU fallback
  local F="$C/Frameworks/Electron Framework.framework/Versions/A"
  ( cd "$F/Resources" && ls -d *.lproj | grep -v -x -e en.lproj -e en_GB.lproj | xargs -r rm -rf )
  ( cd "$C/Resources" && ls -d *.lproj | grep -v -x -e en.lproj -e en_GB.lproj | xargs -r rm -rf )
  rm -f "$F/Libraries/libvk_swiftshader.dylib" "$F/Libraries/vk_swiftshader_icd.json"
  python3 "$ROOT/build/make-dmg.py" "$W/StockPilot" "$OUT/StockPilot-$VERSION-macOS.dmg" StockPilot
}
build "$ELECTRON_MAC_ARM64" AppleSilicon
