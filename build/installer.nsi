; StockPilot Windows installer (one file for Windows 10 / 11, Intel/AMD x64 and ARM64)
; Build: see build/make-windows.sh   (makensis -DVERSION=2.0.0 -DSRC=<staged files> -DOUTFILE=<exe> installer.nsi)
; SRC must contain common\ (shared files + resources\app), x64\ and arm64\ (the per-CPU Electron files).
Unicode true
ManifestDPIAware true
ManifestSupportedOS all

!ifndef VERSION
  !define VERSION "2.0.0"
!endif
!ifndef SRC
  !define SRC "..\dist\win"
!endif
!ifndef OUTFILE
  !define OUTFILE "..\dist\StockPilot Setup ${VERSION}.exe"
!endif
!define UKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\StockPilot"

Name "StockPilot"
Caption "StockPilot ${VERSION} Setup"
OutFile "${OUTFILE}"
InstallDir "$LOCALAPPDATA\Programs\StockPilot"
RequestExecutionLevel user
SetCompressor /SOLID lzma
SetCompressorDictSize 64
BrandingText "StockPilot ${VERSION}"
ShowInstDetails nevershow
ShowUninstDetails nevershow

VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "StockPilot"
VIAddVersionKey "FileDescription" "StockPilot Setup"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "CompanyName" "StockPilot"
VIAddVersionKey "LegalCopyright" "MIT License - fan-made mod for Screen Stocks"

!include MUI2.nsh
!include LogicLib.nsh
!include x64.nsh
!include FileFunc.nsh

!define MUI_ICON "${SRC}\common\icon.ico"
!define MUI_UNICON "${SRC}\common\icon.ico"
!define MUI_ABORTWARNING
!define MUI_WELCOMEPAGE_TITLE "StockPilot ${VERSION}"
!define MUI_WELCOMEPAGE_TEXT "StockPilot is a desktop app for Screen Stocks: live charts, one-click trading, portfolio, dividends, journal, statistics, news, auto actions, an experimental bot and custom skins.$\r$\n$\r$\nIf StockPilot 1.x is installed it is replaced, and your price history, auto actions and settings are brought over.$\r$\n$\r$\nClick Install to continue."
!define MUI_FINISHPAGE_RUN "$INSTDIR\StockPilot.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Open StockPilot"
!define MUI_WELCOMEFINISHPAGE_BITMAP_NOSTRETCH

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

; close StockPilot (2.x and the old 1.x PowerShell version) so files can be replaced
!macro StopStockPilot
  nsExec::Exec 'taskkill /F /T /IM StockPilot.exe'
  Pop $0
  nsExec::Exec `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process | Where-Object { $$_.ProcessId -ne $$PID -and $$_.CommandLine -and ($$_.CommandLine -like '*StockPilot.ps1*' -or $$_.CommandLine -like '*FantaStocks.ps1*' -or $$_.CommandLine -like '*SSBOT_SELF*') } | ForEach-Object { Stop-Process -Id $$_.ProcessId -Force -ErrorAction SilentlyContinue }"`
  Pop $0
  Sleep 700
!macroend

Function .onInit
  ; Windows 10 and 11 only (Windows 10 is the first version with CurrentMajorVersionNumber = 10)
  ReadRegDWORD $0 HKLM "SOFTWARE\Microsoft\Windows NT\CurrentVersion" "CurrentMajorVersionNumber"
  ${If} $0 < 10
    MessageBox MB_ICONSTOP "StockPilot needs Windows 10 or Windows 11." /SD IDOK
    Abort
  ${EndIf}
!ifdef ALLNATIVE
  ; every PC: the native StockPilot for this CPU is installed (ARM64, x64 or x86)
!else ifdef ALLPCS
  ; 32-bit (x86) build: runs natively on x86 and x64, and through Windows' built-in emulation on ARM
!else ifdef ONLYARCH
  ; single-CPU installer (smaller download)
  ${IfNot} ${IsNative${ONLYARCH_CHECK}}
    MessageBox MB_ICONSTOP "This StockPilot setup is for ${ONLYARCH_NAME} PCs. Please use the other StockPilot setup for this PC." /SD IDOK
    Abort
  ${EndIf}
!endif
!ifndef ALLPCS & ALLNATIVE
  ${IfNot} ${IsNativeARM64}
  ${AndIfNot} ${IsNativeAMD64}
    MessageBox MB_ICONSTOP "StockPilot needs 64-bit Windows (Intel/AMD or ARM)." /SD IDOK
    Abort
  ${EndIf}
!endif
FunctionEnd

Section "StockPilot" SecMain
  SetShellVarContext current
  !insertmacro StopStockPilot
  SetOutPath "$INSTDIR"

  ; StockPilot 1.x program files (its data - SSPanelData and ScreenStocksRules.json - stays and is imported on first start)
  Delete "$INSTDIR\StockPilot.ps1"
  Delete "$INSTDIR\FantaStocks.ps1"
  Delete "$INSTDIR\Uninstall.exe"
  ; files from an older 2.x
  RMDir /r "$INSTDIR\resources\app"
  RMDir /r "$INSTDIR\locales"

  File /r "${SRC}\common\*.*"
!ifdef ALLNATIVE
  ${If} ${IsNativeARM64}
    File /r "${SRC}\arm64\*.*"
  ${ElseIf} ${IsNativeAMD64}
    File /r "${SRC}\x64\*.*"
  ${Else}
    File /r "${SRC}\ia32\*.*"
  ${EndIf}
!else ifdef ONLYARCH
  File /r "${SRC}\${ONLYARCH}\*.*"
!else
  ${If} ${IsNativeARM64}
    File /r "${SRC}\arm64\*.*"
  ${Else}
    File /r "${SRC}\x64\*.*"
  ${EndIf}
!endif
  WriteUninstaller "$INSTDIR\Uninstall StockPilot.exe"

  ; old 1.x shortcuts
  RMDir /r "$SMPROGRAMS\StockPilot"
  Delete "$SMPROGRAMS\FantaStocks.lnk"
  Delete "$DESKTOP\FantaStocks.lnk"
  ${If} ${FileExists} "$SMSTARTUP\StockPilot.lnk"
    ; 1.x started with Windows -> tell 2.x to keep doing that (it uses its own setting)
    CreateDirectory "$APPDATA\StockPilot"
    FileOpen $1 "$APPDATA\StockPilot\v1-autostart.flag" w
    FileClose $1
    Delete "$SMSTARTUP\StockPilot.lnk"
  ${EndIf}
  Delete "$SMSTARTUP\FantaStocks.lnk"

  ; Start menu (shows up under "All apps" and in search) + desktop
  CreateShortcut "$SMPROGRAMS\StockPilot.lnk" "$INSTDIR\StockPilot.exe" "" "$INSTDIR\icon.ico" 0 SW_SHOWNORMAL "" "StockPilot for Screen Stocks"
  CreateShortcut "$DESKTOP\StockPilot.lnk" "$INSTDIR\StockPilot.exe" "" "$INSTDIR\icon.ico" 0 SW_SHOWNORMAL "" "StockPilot for Screen Stocks"

  ; Apps & features entry (replaces the 1.x one)
  WriteRegStr HKCU "Software\StockPilot" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\StockPilot" "Version" "${VERSION}"
  DeleteRegKey HKCU "${UKEY}"
  WriteRegStr HKCU "${UKEY}" "DisplayName" "StockPilot"
  WriteRegStr HKCU "${UKEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UKEY}" "Publisher" "StockPilot"
  WriteRegStr HKCU "${UKEY}" "DisplayIcon" "$INSTDIR\icon.ico"
  WriteRegStr HKCU "${UKEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UKEY}" "UninstallString" '"$INSTDIR\Uninstall StockPilot.exe"'
  WriteRegStr HKCU "${UKEY}" "QuietUninstallString" '"$INSTDIR\Uninstall StockPilot.exe" /S'
  WriteRegDWORD HKCU "${UKEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UKEY}" "NoRepair" 1
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  WriteRegDWORD HKCU "${UKEY}" "EstimatedSize" "$0"
SectionEnd

Section "Uninstall"
  SetShellVarContext current
  !insertmacro StopStockPilot
  Delete "$SMPROGRAMS\StockPilot.lnk"
  Delete "$DESKTOP\StockPilot.lnk"
  Delete "$SMSTARTUP\StockPilot.lnk"
  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "StockPilot"

  ; program files only (names listed so nothing else in the folder is touched)
  RMDir /r "$INSTDIR\resources"
  RMDir /r "$INSTDIR\locales"
  Delete "$INSTDIR\StockPilot.exe"
  Delete "$INSTDIR\*.dll"
  Delete "$INSTDIR\*.pak"
  Delete "$INSTDIR\snapshot_blob.bin"
  Delete "$INSTDIR\v8_context_snapshot.bin"
  Delete "$INSTDIR\icudtl.dat"
  Delete "$INSTDIR\vk_swiftshader_icd.json"
  Delete "$INSTDIR\LICENSE"
  Delete "$INSTDIR\LICENSES.chromium.html"
  Delete "$INSTDIR\version"
  Delete "$INSTDIR\icon.ico"
  Delete "$INSTDIR\Uninstall StockPilot.exe"

  MessageBox MB_YESNO|MB_ICONQUESTION "Also delete your StockPilot data?$\r$\n$\r$\n(price history, journal, auto actions, bot and app settings)$\r$\n$\r$\nChoose No to keep it for a later install." /SD IDNO IDNO keepData
    RMDir /r "$APPDATA\StockPilot"
    RMDir /r "$INSTDIR\SSPanelData"
    Delete "$INSTDIR\ScreenStocksRules.json"
  keepData:
  RMDir "$INSTDIR"

  DeleteRegKey HKCU "${UKEY}"
  DeleteRegKey HKCU "Software\StockPilot"
SectionEnd
