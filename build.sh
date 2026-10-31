#!/bin/bash
# rebuild every StockPilot package from StockPilot.ps1 + the installer sources
set -e; F=/home/claude/stockpilot; S=/tmp/claude-0/-home-claude/cc9fbaca-3a71-5a97-8b0e-d2f3ecb9da52/scratchpad; N=$S/nsis; VER=${1:-v1.1}
$F/cwin/build.sh
cp $F/StockPilot.ps1 $F/linux/AppDir/usr/share/stockpilot/ && cd $F/linux && rm -f *.AppImage && ARCH=x86_64 $S/appimagetool --appimage-extract-and-run --runtime-file $S/runtime-x86_64 --no-appstream AppDir StockPilot-x86_64.AppImage > /dev/null 2>&1
cp $F/StockPilot.ps1 "$F/mac/stage/StockPilot.app/Contents/Resources/"; rm -f $F/mac/StockPilot.dmg $F/mac/StockPilot-app-backup.zip
python3 - "$F/mac/stage" "$F/mac/StockPilot.dmg" <<'PY'
import sys, os, io
sys.path.insert(0, '/tmp/claude-0/-home-claude/cc9fbaca-3a71-5a97-8b0e-d2f3ecb9da52/scratchpad/pycdlib_git')
import pycdlib
src, out = sys.argv[1], sys.argv[2]
iso = pycdlib.PyCdlib(); iso.new(interchange_level=3, rock_ridge='1.09', vol_ident='STOCKPILOT')
n = [0]
def nm(d=False):
    n[0] += 1; return ('D%05d' % n[0]) if d else ('F%05d.;1' % n[0])
def walk(local, isodir):
    for name in sorted(os.listdir(local)):
        p = os.path.join(local, name)
        if os.path.isdir(p):
            ip = isodir.rstrip('/') + '/' + nm(True); iso.add_directory(ip, rr_name=name, file_mode=0o040755); walk(p, ip)
        else:
            data = open(p, 'rb').read(); mode = 0o100755 if os.access(p, os.X_OK) else 0o100644
            iso.add_fp(io.BytesIO(data), len(data), isodir.rstrip('/') + '/' + nm(), rr_name=name, file_mode=mode)
walk(src, '/')
iso.add_symlink(symlink_path='/APPLICAT.;1', rr_symlink_name='Applications', rr_path='/Applications')
iso.write(out); iso.close()
PY
cd "$F/mac/stage" && zip -qry ../StockPilot-app-backup.zip "StockPilot.app" "Uninstall StockPilot.app"
P=$S/ffinal/StockPilot-$VER
cp $F/cwin/StockPilot-Setup.exe $F/cwin/StockPilot-Uninstall.exe "$P/Windows/"; cp $F/mac/StockPilot.dmg $F/mac/StockPilot-app-backup.zip "$P/macOS/"; cp $F/linux/StockPilot-x86_64.AppImage "$P/Linux/"; chmod +x "$P/Linux/StockPilot-x86_64.AppImage"
cd $S/ffinal && rm -f /home/claude/StockPilot-$VER.zip && zip -qry /home/claude/StockPilot-$VER.zip StockPilot-$VER
echo "built /home/claude/StockPilot-$VER.zip"
