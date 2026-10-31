param([string]$Phase = 'post', [string]$Dir = '', [string]$Game = '')
$ErrorActionPreference = 'Continue'
if ($Phase -eq 'pre') {
    # close a running bot (old .bat, Screen Stocks Panel or StockPilot) so files aren't in use
    Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and ($_.CommandLine -like '*StockPilot.ps1*' -or $_.CommandLine -like '*FantaStocks.ps1*' -or $_.CommandLine -like '*ScreenStocksPanel.ps1*' -or $_.CommandLine -like '*SSBOT_SELF*') } | ForEach-Object {
        $par = Get-CimInstance Win32_Process -Filter ('ProcessId = ' + $_.ParentProcessId) -ErrorAction SilentlyContinue
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        if ($par -and $par.Name -eq 'cmd.exe') { Stop-Process -Id $par.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 700
    exit 0
}
$game = $Game; if (-not $game) { $game = Join-Path $env:USERPROFILE 'AppData\LocalLow\Conradical Games\Screen Stocks' }
$old = Join-Path $game 'ScreenStocksPanel'
$oldName = Join-Path $game 'FantaStocks'   # early builds (old name) lived here (low-trust folder)
$oldFS = Join-Path $env:LOCALAPPDATA 'Programs\FantaStocks'   # v1.1 under the old name FantaStocks
# keep rules + chart data from older versions
if (-not (Test-Path -LiteralPath (Join-Path $Dir 'ScreenStocksRules.json'))) {
    foreach ($src in @((Join-Path $oldFS 'ScreenStocksRules.json'), (Join-Path $oldName 'ScreenStocksRules.json'), (Join-Path $old 'ScreenStocksRules.json'), (Join-Path $game 'ScreenStocksRules.json'), (Join-Path $env:USERPROFILE 'Downloads\ScreenStocksRules.json'), (Join-Path $env:USERPROFILE 'Desktop\ScreenStocksRules.json'))) {
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $Dir -Force; break }
    }
}
foreach ($o in @($oldFS, $oldName, $old)) {
    if (-not (Test-Path -LiteralPath (Join-Path $Dir 'SSPanelData')) -and (Test-Path -LiteralPath (Join-Path $o 'SSPanelData'))) { Copy-Item -LiteralPath (Join-Path $o 'SSPanelData') -Destination $Dir -Recurse -Force }
}
Remove-Item -LiteralPath (Join-Path $Dir 'SSPanelData\port.txt') -Force -ErrorAction SilentlyContinue
foreach ($o in @($oldFS, $oldName, $old)) { if ((Test-Path -LiteralPath $o) -and ($o -ne $Dir)) { Remove-Item -LiteralPath $o -Recurse -Force -ErrorAction SilentlyContinue } }
$desk = [Environment]::GetFolderPath('Desktop'); $prog = [Environment]::GetFolderPath('Programs')
Remove-Item -LiteralPath (Join-Path $desk 'Screen Stocks Panel.lnk') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $prog 'Screen Stocks Panel') -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ScreenStocksPanel' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path 'HKCU:\Software\ScreenStocksPanel' -Recurse -Force -ErrorAction SilentlyContinue
# old name FantaStocks: shortcuts, start-with-Windows entry, Settings > Apps entry
Remove-Item -LiteralPath (Join-Path $desk 'FantaStocks.lnk') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $prog 'FantaStocks') -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath('Startup')) 'FantaStocks.lnk') -Force -ErrorAction SilentlyContinue
Remove-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\FantaStocks' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path 'HKCU:\Software\FantaStocks' -Recurse -Force -ErrorAction SilentlyContinue
# shortcuts
$ws = New-Object -ComObject WScript.Shell
$sm = Join-Path $prog 'StockPilot'; New-Item -ItemType Directory -Force -Path $sm | Out-Null
function Lnk($path, $target) { $s = $ws.CreateShortcut($path); $s.TargetPath = $target; $s.WorkingDirectory = $Dir; $s.IconLocation = "$Dir\icon.ico,0"; $s.Save() }
Lnk (Join-Path $desk 'StockPilot.lnk') (Join-Path $Dir 'StockPilot.exe')
Lnk (Join-Path $sm 'StockPilot.lnk') (Join-Path $Dir 'StockPilot.exe')
Lnk (Join-Path $sm 'Uninstall StockPilot.lnk') (Join-Path $Dir 'Uninstall.exe')
$su = $ws.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Startup')) 'StockPilot.lnk')); $su.TargetPath = (Join-Path $Dir 'StockPilot.exe'); $su.Arguments = '/background'; $su.WorkingDirectory = $Dir; $su.IconLocation = "$Dir\icon.ico,0"; $su.Save()
# Settings > Apps entry
New-Item -Path 'HKCU:\Software\StockPilot' -Force | Out-Null
Set-ItemProperty -Path 'HKCU:\Software\StockPilot' -Name InstallDir -Value $Dir
$uk = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\StockPilot'
New-Item -Path $uk -Force | Out-Null
$vals = [ordered]@{ DisplayName = 'StockPilot'; DisplayVersion = '1.1'; Publisher = 'StockPilot (fan-made mod for Screen Stocks)'; DisplayIcon = (Join-Path $Dir 'icon.ico'); InstallLocation = $Dir; UninstallString = ('"' + (Join-Path $Dir 'Uninstall.exe') + '"') }
foreach ($k in $vals.Keys) { Set-ItemProperty -Path $uk -Name $k -Value $vals[$k] }
Set-ItemProperty -Path $uk -Name NoModify -Value 1 -Type DWord
Set-ItemProperty -Path $uk -Name NoRepair -Value 1 -Type DWord
exit 0
