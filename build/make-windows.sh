#!/usr/bin/env bash
# Builds "StockPilot Setup <version> ARM64.exe" and "StockPilot Setup <version> x64.exe" for Windows 10/11 (~70 MB each).
# Runs on Linux or macOS. Needs: python3, llvm-rc, makensis (NSIS 3.x) and the two Electron Windows zips:
#   ELECTRON_X64=electron-v38.2.2-win32-x64.zip  ELECTRON_ARM64=electron-v38.2.2-win32-arm64.zip  ./build/make-windows.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(python3 -c "import json;print(json.load(open('$ROOT/package.json'))['version'])")"
OUT="$ROOT/dist"; STAGE="$OUT/win"
: "${ELECTRON_X64:?set ELECTRON_X64 to the electron win32-x64 zip}"; : "${ELECTRON_ARM64:?set ELECTRON_ARM64 to the electron win32-arm64 zip}"
MAKENSIS="${MAKENSIS:-makensis}"

rm -rf "$STAGE"; mkdir -p "$STAGE/common/resources/app/build" "$STAGE/x64" "$STAGE/arm64"
unzip -q "$ELECTRON_X64" -d "$STAGE/x64"; unzip -q "$ELECTRON_ARM64" -d "$STAGE/arm64"

# exe name, icon and version info ("StockPilot" in Task Manager instead of "Electron")
llvm-rc /FO "$OUT/resources.res" "$ROOT/build/exe.rc"
for a in x64 arm64; do
  mv "$STAGE/$a/electron.exe" "$STAGE/$a/StockPilot.exe"
  rm -f "$STAGE/$a/resources/default_app.asar"
  python3 "$ROOT/build/set-exe-info.py" "$STAGE/$a/StockPilot.exe" "$OUT/resources.res"
done

# the app itself
cp -r "$ROOT/main.js" "$ROOT/preload.js" "$ROOT/package.json" "$ROOT/backend" "$ROOT/ui" "$STAGE/common/resources/app/"
cp "$ROOT/build/icon.ico" "$ROOT/build/icon.png" "$STAGE/common/resources/app/build/"
cp "$ROOT/build/icon.ico" "$STAGE/common/icon.ico"

# files that are the same for both CPUs are stored once
( cd "$STAGE/x64" && find . -type f | while read -r f; do
    if [ -f "../arm64/$f" ] && cmp -s "$f" "../arm64/$f"; then mkdir -p "../common/$(dirname "$f")"; mv "$f" "../common/$f"; rm "../arm64/$f"; fi
  done )
find "$STAGE/x64" "$STAGE/arm64" -type d -empty -delete

# smaller download: English UI files only, no software-GPU fallback (Windows 10/11 have their own D3D compiler)
( cd "$STAGE/common/locales" && ls | grep -v -x -e en-US.pak -e en-GB.pak | xargs rm -f )
rm -f "$STAGE/common/vk_swiftshader_icd.json"
for a in x64 arm64; do rm -f "$STAGE/$a/vk_swiftshader.dll" "$STAGE/$a/vulkan-1.dll" "$STAGE/$a/d3dcompiler_47.dll"; done

"$MAKENSIS" -V2 -DVERSION="$VERSION" -DSRC="$STAGE" -DONLYARCH=arm64 -DONLYARCH_CHECK=ARM64 "-DONLYARCH_NAME=ARM (Snapdragon)" "-DOUTFILE=$OUT/StockPilot Setup $VERSION ARM64.exe" "$ROOT/build/installer.nsi"
"$MAKENSIS" -V2 -DVERSION="$VERSION" -DSRC="$STAGE" -DONLYARCH=x64 -DONLYARCH_CHECK=AMD64 "-DONLYARCH_NAME=Intel / AMD (x64)" "-DOUTFILE=$OUT/StockPilot Setup $VERSION x64.exe" "$ROOT/build/installer.nsi"
echo "Built: $OUT/StockPilot Setup $VERSION ARM64.exe + x64.exe"
# (leave out -DONLYARCH to get one bigger installer that contains both)

# One installer for every Windows PC (installs the native x64, ARM64 or x86 build), ~210 MB:
#   ELECTRON_IA32=electron-v38.2.2-win32-ia32.zip -> "StockPilot Setup <version>.exe"
# Uses the unmodified Electron exes (shortcuts get the icon from icon.ico).
if [ -n "${ELECTRON_IA32:-}" ]; then
  python3 - "$OUT/win-all" "$ELECTRON_X64" "$ELECTRON_ARM64" "$ELECTRON_IA32" "$ROOT" <<'PY'
import os, sys, shutil, subprocess, filecmp
P, zx, za, zi, R = sys.argv[1:6]
shutil.rmtree(P, ignore_errors=True); os.makedirs(P + '/common/resources/app/build')
for arch, z in (('x64', zx), ('arm64', za), ('ia32', zi)):
    d = os.path.join(P, arch); os.makedirs(d); subprocess.run(['unzip', '-q', z, '-d', d], check=True)
    os.rename(os.path.join(d, 'electron.exe'), os.path.join(d, 'StockPilot.exe'))
    os.remove(os.path.join(d, 'resources', 'default_app.asar'))
    for f in os.listdir(os.path.join(d, 'locales')):
        if f not in ('en-US.pak', 'en-GB.pak'): os.remove(os.path.join(d, 'locales', f))
for root, _, files in os.walk(P + '/x64'):
    for f in files:
        rel = os.path.relpath(os.path.join(root, f), P + '/x64'); a, b, c = [os.path.join(P, x, rel) for x in ('x64', 'arm64', 'ia32')]
        if os.path.isfile(b) and os.path.isfile(c) and filecmp.cmp(a, b, False) and filecmp.cmp(a, c, False):
            dst = os.path.join(P, 'common', rel); os.makedirs(os.path.dirname(dst), exist_ok=True); os.rename(a, dst); os.remove(b); os.remove(c)
for f in ('main.js', 'preload.js', 'package.json'): shutil.copy(os.path.join(R, f), P + '/common/resources/app/')
for d in ('backend', 'ui'): shutil.copytree(os.path.join(R, d), P + '/common/resources/app/' + d)
for f in ('icon.ico', 'icon.png'): shutil.copy(os.path.join(R, 'build', f), P + '/common/resources/app/build/')
shutil.copy(os.path.join(R, 'build', 'icon.ico'), P + '/common/icon.ico')
PY
  "$MAKENSIS" -V2 -DVERSION="$VERSION" -DSRC="$OUT/win-all" -DALLNATIVE "-DOUTFILE=$OUT/StockPilot Setup $VERSION.exe" "$ROOT/build/installer.nsi"
  echo "Built: $OUT/StockPilot Setup $VERSION.exe (every Windows PC)"
fi
