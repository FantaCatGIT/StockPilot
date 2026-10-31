param([string]$InstallDir = '', [switch]$SkipModOff, [switch]$CloseGame)
# exit 0 = done, exit 3 = the game is still open (its name is printed)
$ErrorActionPreference = 'Continue'
$SavName = 'thesmallshort_online_settings.sav'
$game = Join-Path $env:USERPROFILE 'AppData\LocalLow\Conradical Games\Screen Stocks'
function Find-Game { @(Get-Process -ErrorAction SilentlyContinue | Where-Object { (($_.ProcessName -like '*Screen*Stock*') -and ($_.ProcessName -notlike '*Panel*')) -or ($_.ProcessName -like '*Small*Short*') }) }
# 1) stop the running bot (old .bat version or the panel)
try {
    Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and ($_.CommandLine -like '*StockPilot.ps1*' -or $_.CommandLine -like '*FantaStocks.ps1*' -or $_.CommandLine -like '*ScreenStocksPanel.ps1*' -or $_.CommandLine -like '*SSBOT_SELF*') } | ForEach-Object {
        $par = Get-CimInstance Win32_Process -Filter "ProcessId = $($_.ParentProcessId)" -ErrorAction SilentlyContinue
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        if ($par -and $par.Name -eq 'cmd.exe') { Stop-Process -Id $par.ProcessId -Force -ErrorAction SilentlyContinue }
    }
} catch { }
Start-Sleep -Milliseconds 800
# 2) switch mod support off (the game must be closed or it writes the setting back)
$sav = Join-Path $game $SavName
if (-not $SkipModOff -and (Test-Path -LiteralPath $sav)) {
    $text = [IO.File]::ReadAllText($sav)
    if ($text -match '"modSupport"\s*:\s*"?true"?') {
        $g = Find-Game
        if ($g.Count -and $CloseGame) {
            $g | ForEach-Object { try { $_.CloseMainWindow() | Out-Null } catch { } }
            for ($i = 0; $i -lt 10 -and (Find-Game).Count; $i++) { Start-Sleep -Milliseconds 500 }
            Find-Game | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            $g = Find-Game
            $text = [IO.File]::ReadAllText($sav)
        }
        if ($g.Count) { Write-Output (($g | ForEach-Object { $_.ProcessName + '.exe' } | Select-Object -Unique) -join ', '); exit 3 }
        $bytes = [IO.File]::ReadAllBytes($sav)
        $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $new = [regex]::Replace($text, '("modSupport"\s*:\s*)(")?true(")?', '${1}${2}false${3}')
        [IO.File]::WriteAllText($sav, $new, (New-Object System.Text.UTF8Encoding($bom)))
    }
}
# 3) delete what the mod created (custom skins in mods\skins are kept)
$t = @()
foreach ($n in @('StockPilot', 'FantaStocks', 'ScreenStocksPanel', 'ScreenStocksPanel.bat', 'ScreenStocksAutoBot.bat', 'ScreenStocksRules.json', 'SSPanelData', "$SavName.backup")) { $t += (Join-Path $game $n) }
$t += (Join-Path $game 'mods\commands'); $t += (Join-Path $game 'mods\export')
foreach ($pl in @((Join-Path $env:USERPROFILE 'Downloads'), (Join-Path $env:USERPROFILE 'Desktop'))) {
    foreach ($n in @('ScreenStocksPanel.bat', 'ScreenStocksPanel.zip', 'ScreenStocksAutoBot.bat', 'ScreenStocksRules.json', 'SSPanelData', 'screen_stocks_rules.py', 'UninstallScreenStocksMod.bat')) { $t += (Join-Path $pl $n) }
    if (Test-Path -LiteralPath (Join-Path $pl 'screen_stocks_rules.py')) { $t += (Join-Path $pl 'rules.json'); $t += (Join-Path $pl 'run.bat') }
    Get-ChildItem -LiteralPath $pl -Filter '*Stocks*.lnk' | Where-Object { $_.Name -like 'StockPilot*' -or $_.Name -like 'FantaStocks*' -or $_.Name -like 'ScreenStocksPanel*' -or $_.Name -like 'Screen Stocks Panel*' } -ErrorAction SilentlyContinue | ForEach-Object { $t += $_.FullName }
}
if ($InstallDir) {
    foreach ($n in @('StockPilot.ps1', 'StockPilot.exe', 'README.txt', 'icon.ico', 'ScreenStocksRules.json', 'SSPanelData')) { $t += (Join-Path $InstallDir $n) }
}
foreach ($p in $t) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue } }
# 4) shortcuts + Settings > Apps entry (this and older versions)
$desk = [Environment]::GetFolderPath('Desktop'); $prog = [Environment]::GetFolderPath('Programs')
foreach ($p in @((Join-Path ([Environment]::GetFolderPath('Startup')) 'StockPilot.lnk'), (Join-Path ([Environment]::GetFolderPath('Startup')) 'FantaStocks.lnk'), (Join-Path $desk 'StockPilot.lnk'), (Join-Path $desk 'FantaStocks.lnk'), (Join-Path $prog 'FantaStocks'), (Join-Path $env:LOCALAPPDATA 'Programs\FantaStocks'), (Join-Path $desk 'Screen Stocks Panel.lnk'), (Join-Path $prog 'StockPilot'), (Join-Path $prog 'Screen Stocks Panel'))) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
foreach ($k in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\StockPilot', 'HKCU:\Software\StockPilot', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\FantaStocks', 'HKCU:\Software\FantaStocks', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ScreenStocksPanel', 'HKCU:\Software\ScreenStocksPanel')) { Remove-Item -Path $k -Recurse -Force -ErrorAction SilentlyContinue }
exit 0
