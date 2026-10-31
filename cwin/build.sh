#!/bin/bash
# rebuild the native Windows launcher, uninstaller and installer from StockPilot.ps1
set -e; C=/home/claude/stockpilot/cwin; cd $C
LM=/tmp/claude-0/-home-claude/cc9fbaca-3a71-5a97-8b0e-d2f3ecb9da52/scratchpad/llvm-mingw-20241119-ucrt-ubuntu-20.04-x86_64/bin
CC="$LM/x86_64-w64-mingw32-clang"; RC="$LM/x86_64-w64-mingw32-windres"; CA="$LM/aarch64-w64-mingw32-clang"; RA="$LM/aarch64-w64-mingw32-windres"; FL="-municode -mwindows -Os -s -static -w"
emb() { python3 - "$@" <<'PY'
import sys
out=sys.argv[1]; pairs=sys.argv[2:]
with open(out,'w') as f:
    for i in range(0,len(pairs),2):
        d=open(pairs[i+1],'rb').read(); f.write(f'static const unsigned char {pairs[i]}[{len(d)}] = {{' + ','.join(map(str,d)) + '};\n')
PY
}
$RC launcher.rc -O coff -o launcher.res && $CC $FL launcher.c launcher.res -lws2_32 -lshell32 -o StockPilot.exe
$RA launcher.rc -O coff -o launcher_a.res && $CA $FL launcher.c launcher_a.res -lws2_32 -lshell32 -o StockPilot-arm64.exe
emb payload_uninstall.h uninstall_ps1 uninstall.ps1
$RC uninstaller.rc -O coff -o uninstaller.res && $CC $FL uninstaller.c uninstaller.res -ladvapi32 -o StockPilot-Uninstall.exe
$RA uninstaller.rc -O coff -o uninstaller_a.res && $CA $FL uninstaller.c uninstaller_a.res -ladvapi32 -o StockPilot-Uninstall-arm64.exe
cp /home/claude/stockpilot/StockPilot.ps1 .
emb payload_setup.h setup_ps1 setup.ps1 stockpilot_ps1 StockPilot.ps1 stockpilot_exe StockPilot.exe stockpilot_exe_arm64 StockPilot-arm64.exe uninstall_exe StockPilot-Uninstall.exe uninstall_exe_arm64 StockPilot-Uninstall-arm64.exe icon_ico icon.ico
$RC installer.rc -O coff -o installer.res && $CC $FL installer.c installer.res -ladvapi32 -lshell32 -o StockPilot-Setup.exe
