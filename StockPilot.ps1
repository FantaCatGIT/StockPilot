# StockPilot - auto rules bot, charts, profit tracker, calculator.
# Uses the game's OFFICIAL mod support. Runs on Windows PowerShell 5.1 and PowerShell 7 (macOS / Linux).
param([switch]$Background, [switch]$NoOpen)
$ErrorActionPreference = 'Stop'
$Version = '1.1'
$AppId   = 4356780
$Self    = $PSCommandPath; if (-not $Self) { $Self = $env:SSBOT_SELF }
$Here    = Split-Path -Parent $Self
$Root    = $Here; if ($env:SSBOT_DATA) { $Root = $env:SSBOT_DATA }
[void][IO.Directory]::CreateDirectory($Root)
$Rules   = Join-Path $Root 'ScreenStocksRules.json'
$DataDir = Join-Path $Root 'SSPanelData'
$HistDir = Join-Path $DataDir 'history'
$LogFile = Join-Path $DataDir 'log.txt'
$IsWin   = ($env:OS -eq 'Windows_NT')
if ($Background -or $NoOpen) { $env:SSBOT_NOOPEN = '1' }
$IsMac   = (-not $IsWin) -and (Test-Path -LiteralPath '/System/Library/CoreServices')
$SavName = 'thesmallshort_online_settings.sav'
$GameDir = $null
if ($env:SSBOT_GAMEDIR) { $GameDir = $env:SSBOT_GAMEDIR }
elseif (Test-Path -LiteralPath (Join-Path $Root $SavName)) { $GameDir = $Root }
elseif (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $Root) $SavName)) { $GameDir = Split-Path -Parent $Root }
else {
    $tries = @()
    if ($env:USERPROFILE) { $tries += (Join-Path $env:USERPROFILE 'AppData\LocalLow\Conradical Games\Screen Stocks') }
    if ($env:HOME) {
        $tries += (Join-Path $env:HOME 'Library/Application Support/Conradical Games/Screen Stocks')
        $tail = 'steamapps/compatdata/4356780/pfx/drive_c/users/steamuser/AppData/LocalLow/Conradical Games/Screen Stocks'
        foreach ($r in @('.local/share/Steam', '.steam/steam', '.var/app/com.valvesoftware.Steam/.local/share/Steam')) { $tries += (Join-Path (Join-Path $env:HOME $r) $tail) }
    }
    foreach ($d in $tries) { if (Test-Path -LiteralPath (Join-Path $d $SavName)) { $GameDir = $d; break } }
    if (-not $GameDir) {
        if ($IsWin -and $tries.Count) { $GameDir = $tries[0] }
        elseif ($IsMac) { $GameDir = $tries | Where-Object { $_ -like '*Library*' } | Select-Object -First 1 }
        elseif ($tries.Count) { $GameDir = $tries | Where-Object { $_ -like '*compatdata*' } | Select-Object -First 1 }
    }
}
$Sav     = Join-Path $GameDir $SavName
$Export  = Join-Path (Join-Path $GameDir 'mods') 'export'
$Cmds    = Join-Path (Join-Path $GameDir 'mods') 'commands'
$MarketFile = Join-Path $Export 'market.json'
$Utf8    = New-Object System.Text.UTF8Encoding($false)
$Inv     = [Globalization.CultureInfo]::InvariantCulture
$Actions = @('buy', 'sell', 'short', 'cover', 'close')
$NWID    = '__NW'
$HelpLines = @(
    'Easiest: edit your auto actions in the StockPilot window. You can also edit this file in a text editor.',
    'dry_run true = PRACTICE (only shows what it would do). false = LIVE (really trades).',
    'Each auto action: stock, action (buy / sell / short / cover / close), when (below / above), price, percent (1-100, 100 = max).',
    'Optional: "repeat": true keeps firing while the price stays past the line. "enabled": false switches an auto action off.'
)

$global:Log = New-Object System.Collections.ArrayList
$global:LogId = 0
$global:Armed = @{}; $global:Warned = @{}; $global:Seen = @{}
$global:LastSeq = $null; $global:LastSeqAt = Get-Date
$global:Paused = $false; $global:Market = $null; $global:Quit = $false
$global:Connected = $false; $global:StatusMsg = 'Starting...'
$global:LiveData = @{}; $global:DayData = @{}; $global:DayCache = @{}; $global:Names = @{}
$global:WriteBuf = @{}; $global:LastW = @{}; $global:FastIO = $false; $global:MarketStamp = 0L; $global:NextDaily = [DateTime]::MinValue
$global:DayKey = ''; $global:NextRecord = [DateTime]::MinValue
$global:Daily = @{}; $global:NetWorth = $null; $global:NetWorthEst = $true
$global:Trades = New-Object System.Collections.ArrayList
$global:PrevPos = @{}; $global:LastCmdAt = @{}
$global:LastBuySent = [DateTime]::MinValue; $global:LastShortSent = [DateTime]::MinValue
$global:Doc = $null; $global:Active = @(); $global:RulesVersion = 0; $global:RulesError = ''; $global:RulesTime = $null
$global:Settings = @{ pin = $true; autoGame = $true; awake = $true }; $global:AutoGameAt = $null; $global:AwakeOk = $false; $global:PinOk = $false; $global:PinUntil = [DateTime]::MinValue
$global:SetupState = 'start'; $global:SetupMsg = ''; $global:LaunchedOnce = $false; $global:ClosedAt = $null; $global:NextSetup = Get-Date

# ------------------------------------------------------------------ helpers
function Say($msg, $color = 'Gray') {
    $kind = 'dim'
    if ($color -eq 'Green') { $kind = 'ok' } elseif ($color -eq 'Red') { $kind = 'err' } elseif ($color -eq 'Yellow') { $kind = 'warn' } elseif ($color -eq 'Cyan') { $kind = 'info' }
    $global:LogId++
    $t = (Get-Date).ToString('HH:mm:ss')
    [void]$global:Log.Add(@{ id = $global:LogId; t = $t; msg = "$msg"; kind = $kind })
    while ($global:Log.Count -gt 200) { $global:Log.RemoveAt(0) }
    try { Write-Host "[$t] $msg" -ForegroundColor $color } catch { }
    try { [IO.File]::AppendAllText($LogFile, ((Get-Date).ToString('yyyy-MM-dd ') + "[$t] $msg`n"), $Utf8) } catch { }
}
function Num($x) {
    if ($null -eq $x -or "$x" -eq '') { return 0.0 }
    try { return [double]$x } catch { return 0.0 }
}
function Norm($s) { return ("$s").Trim().TrimStart([char]'$').ToUpper() }
function NowMs { return [double]([DateTimeOffset]::Now.ToUnixTimeMilliseconds()) }
function SafeName($s) { return ("$s" -replace '[^A-Za-z0-9_\-]', '_') }
function Fmt-Short([double]$n) {
    $a = [math]::Abs($n)
    foreach ($u in @(@(1e27, 'Oc'), @(1e24, 'Sp'), @(1e21, 'Sx'), @(1e18, 'Qi'), @(1e15, 'Qa'), @(1e12, 'T'), @(1e9, 'B'), @(1e6, 'M'), @(1e3, 'K'))) { if ($a -ge $u[0]) { return ($n / $u[0]).ToString('0.##', $Inv) + $u[1] } }
    return $n.ToString('0.###', $Inv)
}
function Read-Text($path) {
    $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $sr = New-Object IO.StreamReader($fs, $true)
    try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
}
function Read-Json($path) {
    for ($i = 0; $i -lt 5; $i++) {
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        try { return (Read-Text $path | ConvertFrom-Json) } catch { Start-Sleep -Milliseconds 60 }
    }
    return $null
}
function Game-Running {
    $p = Get-Process -ErrorAction SilentlyContinue | Where-Object { (($_.ProcessName -like '*Screen*Stock*') -and ($_.ProcessName -notlike '*Panel*')) -or ($_.ProcessName -like '*Small*Short*') }
    return [bool]$p
}
function Launch-Game {
    try {
        if ($IsMac) { Start-Process 'open' -ArgumentList "steam://rungameid/$AppId" }
        elseif ($IsWin) { Start-Process "steam://rungameid/$AppId" }
        else { Start-Process 'xdg-open' -ArgumentList "steam://rungameid/$AppId" }
        Say 'Opening Screen Stocks from Steam...' Cyan
    } catch { Say 'Open Screen Stocks from Steam.' Yellow }
}

# -------------------------------------------------------------------- setup
function Setup-Step {
    if ($global:SetupState -eq 'ok' -or (Get-Date) -lt $global:NextSetup) { return }
    $global:NextSetup = (Get-Date).AddSeconds(2)
    if (-not (Test-Path -LiteralPath $Sav)) {
        $global:SetupState = 'nosave'
        $global:SetupMsg = 'Open Screen Stocks once (then close it) so it creates its settings. The panel finishes setup by itself.'
        return
    }
    $text = Read-Text $Sav
    if ($text -match '"modSupport"\s*:\s*"?true"?') {
        $global:SetupState = 'ok'; $global:SetupMsg = ''
        Say 'Mod support: ON' Green
        return
    }
    if ($text -notmatch '"modSupport"') {
        $global:SetupState = 'noopt'; $global:SetupMsg = 'Your game has no mod support option yet. Update Screen Stocks on Steam, open it once and close it.'
        return
    }
    if (Game-Running) {
        $global:SetupState = 'close'; $global:ClosedAt = $null
        $global:SetupMsg = 'Close Screen Stocks for a moment so mod support can be switched on, then open it again.'
        return
    }
    if ($global:SetupState -eq 'close') {
        if ($null -eq $global:ClosedAt) { $global:ClosedAt = Get-Date; return }
        if (((Get-Date) - $global:ClosedAt).TotalSeconds -lt 2) { return }
    }
    $bytes = [IO.File]::ReadAllBytes($Sav)
    $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    Copy-Item -LiteralPath $Sav -Destination ($Sav + '.backup') -Force
    $new = [regex]::Replace($text, '("modSupport"\s*:\s*)(")?false(")?', '${1}${2}true${3}')
    [IO.File]::WriteAllText($Sav, $new, (New-Object System.Text.UTF8Encoding($bom)))
    Say 'Mod support: switched ON (old settings saved as .backup). You can open Screen Stocks now.' Green
    $global:SetupState = 'ok'; $global:SetupMsg = ''
}

# -------------------------------------------------------------------- rules
function Rule-Key($n) { return ((Norm $n.stock) + '|' + $n.action + '|' + $n.when + '|' + ([double]$n.price).ToString($Inv) + '|' + $n.percent) }
function Normalize-Rule($r) {
    if ($null -eq $r) { return $null }
    $pct = 100
    if ($null -ne $r.percent -and "$($r.percent)" -ne '') { $pct = [int][math]::Max(1, [math]::Min(100, (Num $r.percent))) }
    return [ordered]@{
        stock = ("$($r.stock)").Trim(); action = ("$($r.action)").Trim().ToLower(); when = ("$($r.when)").Trim().ToLower()
        price = (Num $r.price); percent = $pct; repeat = ($r.repeat -eq $true); enabled = ($r.enabled -ne $false)
    }
}
function Check-Rule($n) {
    if (-not $n.stock) { return 'pick a stock' }
    if ($Actions -notcontains $n.action) { return 'action must be buy, sell, short, cover or close' }
    if (@('below', 'above') -notcontains $n.when) { return 'when must be below or above' }
    if ($n.price -le 0) { return 'set a price' }
    return $null
}
function Save-Rules($dry, $list) {
    $arr = @(); foreach ($r in $list) { $arr += [pscustomobject]$r }
    $doc = [pscustomobject][ordered]@{ help = $HelpLines; dry_run = [bool]$dry; rules = $arr }
    [IO.File]::WriteAllText($Rules, ($doc | ConvertTo-Json -Depth 6), $Utf8)
}
function Apply-Rules {
    try { $global:RulesTime = (Get-Item -LiteralPath $Rules).LastWriteTimeUtc } catch { }
    $d = Read-Json $Rules
    if ($null -eq $d) {
        $global:RulesError = 'ScreenStocksRules.json has a typo (not valid JSON). Fix it in a text editor, or change any auto action here to re-save it.'
        Say $global:RulesError Red; return $false
    }
    $list = New-Object System.Collections.ArrayList
    foreach ($r in @($d.rules)) { $n = Normalize-Rule $r; if ($n) { [void]$list.Add($n) } }
    $doc = @{ dry = ($d.dry_run -ne $false); rules = $list }
    $active = @(); $i = 0
    foreach ($n in $list) {
        $i++
        if (-not $n.enabled) { continue }
        $bad = Check-Rule $n
        if ($bad) { Say "Rule $i skipped: $bad" Yellow; continue }
        $active += [pscustomobject]@{ Id = $i; Stock = $n.stock; Action = $n.action; When = $n.when; Price = $n.price; Percent = $n.percent; Repeat = $n.repeat; Key = (Rule-Key $n) }
    }
    if ($global:Doc -and ($global:Doc.dry -ne $doc.dry)) {
        $global:Armed.Clear()
        if ($doc.dry) { Say 'Mode: PRACTICE (nothing is traded)' Yellow } else { Say 'Mode: LIVE - auto actions really trade now' Green }
    }
    $global:Doc = $doc; $global:Active = $active; $global:Warned.Clear()
    $global:RulesError = ''; $global:RulesVersion++
    return $true
}
function Mode-Name { if ($global:Doc.dry) { 'PRACTICE' } else { 'LIVE' } }
function Describe($r) {
    if ($r.Percent -ge 100) { $size = 'MAX' } else { $size = "$($r.Percent)%" }
    return "$($r.Action.ToUpper()) $($r.Stock) $size when $($r.When) $($r.Price.ToString($Inv))"
}

# ------------------------------------------------------------------ trading
function Send-Cmd($sid, $r) {
    if ($global:Doc.dry) { Say "[PRACTICE] would fire: $(Describe $r)" Cyan; return $true }
    $dir = Join-Path $Cmds $sid
    if (-not (Test-Path -LiteralPath $dir)) { Say "No command folder for $sid yet." Red; return $false }
    if ($r.Percent -ge 100) { $path = Join-Path $dir "$($r.Action)max.json"; $json = '{ "execute": true }' }
    else { $path = Join-Path $dir "$($r.Action)percent.json"; $json = '{ "execute": true, "percent": ' + $r.Percent + ' }' }
    $cur = Read-Json $path
    if ($cur -and $cur.execute -eq $true) { return $false }
    try { [IO.File]::WriteAllText($path, $json, $Utf8) } catch { Say "Could not write $path" Red; return $false }
    $global:LastCmdAt[$sid] = Get-Date
    Say "[SENT] $(Describe $r)" Green
    return $true
}
function Run-Cycle($m) {
    $player = $m.player
    $now = Num $m.serverTimeMs
    $pos = @{}; foreach ($p in @($player.positions)) { if ($p) { $pos["$($p.stockId)"] = $p } }
    $lookup = @{}; $stocks = @{}
    foreach ($s in @($m.stocks)) {
        if (-not $s) { continue }
        $sid = "$($s.stockId)"; $stocks[$sid] = $s; $lookup[(Norm $sid)] = $sid
        if ($s.name) { $lookup[(Norm $s.name)] = $sid }
    }
    foreach ($res in @($m.commandResults)) {
        if ($null -eq $res) { continue }
        $k = $res | ConvertTo-Json -Compress -Depth 5
        if (-not $global:Seen.ContainsKey($k)) { $global:Seen[$k] = 1; Say "Game: $k" Gray }
    }
    $bought = ((Get-Date) - $global:LastBuySent).TotalSeconds -lt 2
    $shorted = ((Get-Date) - $global:LastShortSent).TotalSeconds -lt 2
    foreach ($r in $global:Active) {
        $sid = $lookup[(Norm $r.Stock)]
        if (-not $sid) {
            if (-not $global:Warned.ContainsKey($r.Key)) { $global:Warned[$r.Key] = 1; Say "Rule $($r.Id): stock $($r.Stock) not found in the game." Yellow }
            continue
        }
        $s = $stocks[$sid]
        if ($s.unlocked -eq $false) { continue }
        $price = Num $s.price
        if ($r.When -eq 'below') { $hit = $price -lt $r.Price } else { $hit = $price -gt $r.Price }
        if (-not $hit) { $global:Armed[$r.Key] = $true; continue }
        $isArmed = (-not $global:Armed.ContainsKey($r.Key)) -or $global:Armed[$r.Key]
        if (-not $isArmed -and -not $r.Repeat) { continue }
        $p = $pos[$sid]; $owned = 0; $shortQ = 0
        if ($p) { $owned = Num $p.sharesOwned; $shortQ = Num $p.sharesShorted }
        $skip = $false
        if ($r.Action -eq 'buy')   { $skip = $bought -or ($now -lt (Num $player.nextBuyAtMs)) }
        if ($r.Action -eq 'short') { $skip = $shorted -or ($now -lt (Num $player.nextShortAtMs)) }
        if ($r.Action -eq 'sell')  { $skip = $owned -le 0 }
        if ($r.Action -eq 'cover') { $skip = $shortQ -le 0 }
        if ($r.Action -eq 'close') { $skip = ($owned -le 0) -and ($shortQ -le 0) }
        if ($skip) { continue }
        if (Send-Cmd $sid $r) {
            $global:Armed[$r.Key] = $false
            if ($r.Action -eq 'buy') { $bought = $true; $global:LastBuySent = Get-Date }
            if ($r.Action -eq 'short') { $shorted = $true; $global:LastShortSent = Get-Date }
        }
    }
}

# ---------------------------------------------------------------- recording
function Get-NetWorth($m) {
    $pl = $m.player
    foreach ($k in @('netWorth', 'networth', 'net_worth', 'totalWorth', 'worth')) {
        $v = $pl.$k
        if ($null -ne $v -and "$v" -ne '') { return @((Num $v), $false) }
    }
    $prices = @{}; foreach ($s in @($m.stocks)) { if ($s) { $prices["$($s.stockId)"] = Num $s.price } }
    $nw = Num $pl.cash
    foreach ($p in @($pl.positions)) {
        if (-not $p) { continue }
        $px = $prices["$($p.stockId)"]; if ($null -eq $px) { $px = 0.0 }
        $nw += (Num $p.sharesOwned) * $px
        $sh = Num $p.sharesShorted
        if ($sh -gt 0) { $avg = Num $p.averageShortPrice; if ($avg -le 0) { $avg = $px }; $nw += $sh * (2 * $avg - $px) }
    }
    return @($nw, $true)
}
function New-Series { return , (New-Object 'System.Collections.Generic.List[double[]]') }
function Add-Point($table, $sid, $t, $p) {
    $l = $table[$sid]
    if ($null -eq $l) { $l = New-Series; $table[$sid] = $l }
    $l.Add([double[]]@($t, $p))
}
$FastCode = @'
using System; using System.IO; using System.Globalization; using System.Collections.Generic;
public static class SSData {
    public static List<double[]> Read(string path, double gap) {
        List<double[]> l = new List<double[]>();
        if (!File.Exists(path)) return l;
        CultureInfo inv = CultureInfo.InvariantCulture; NumberStyles sty = NumberStyles.Float;
        double[] mn = null, mx = null, last = null; double bucket = double.NaN;
        using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        using (StreamReader r = new StreamReader(fs)) {
            string line;
            while ((line = r.ReadLine()) != null) {
                int i = line.IndexOf(','); if (i < 1) continue;
                double t, p;
                if (!double.TryParse(line.Substring(0, i), sty, inv, out t) || !double.TryParse(line.Substring(i + 1), sty, inv, out p)) continue;
                double[] pt = new double[] { t, p }; last = pt;
                if (gap <= 0) { l.Add(pt); continue; }
                double b = Math.Floor(t / gap);
                if (b != bucket) { Emit(l, mn, mx); bucket = b; mn = pt; mx = pt; }
                else { if (p < mn[1]) mn = pt; if (p > mx[1]) mx = pt; }
            }
        }
        if (gap > 0) { Emit(l, mn, mx); if (last != null && (l.Count == 0 || l[l.Count - 1][0] < last[0])) l.Add(last); }
        return l;
    }
    static void Emit(List<double[]> l, double[] mn, double[] mx) {
        if (mn == null) return;
        if (mn == mx) { l.Add(mn); return; }
        if (mn[0] <= mx[0]) { l.Add(mn); l.Add(mx); } else { l.Add(mx); l.Add(mn); }
    }
    public static List<double[]> ThinList(List<double[]> src, double gap) {
        if (gap <= 0 || src.Count == 0) return src;
        List<double[]> l = new List<double[]>(); double[] mn = null, mx = null; double bucket = double.NaN;
        foreach (double[] pt in src) {
            double b = Math.Floor(pt[0] / gap);
            if (b != bucket) { Emit(l, mn, mx); bucket = b; mn = pt; mx = pt; }
            else { if (pt[1] < mn[1]) mn = pt; if (pt[1] > mx[1]) mx = pt; }
        }
        Emit(l, mn, mx);
        double[] last = src[src.Count - 1]; if (l[l.Count - 1][0] < last[0]) l.Add(last);
        return l;
    }
    public static void SortList(List<double[]> l) { l.Sort(delegate(double[] a, double[] b) { return a[0].CompareTo(b[0]); }); }
    // own recordings + points shared by other players, merged in time order
    public static List<double[]> ReadMany(string[] paths, double gap) {
        List<double[]> raw = new List<double[]>(); int files = 0;
        foreach (string p in paths) { if (File.Exists(p)) { raw.AddRange(Read(p, 0)); files++; } }
        if (files > 1) SortList(raw);
        return ThinList(raw, gap);
    }
    public static void Thin(string path, double gap) {
        List<double[]> l = ThinList(ReadMany(new string[] { path }, 0), gap);
        System.Text.StringBuilder sb = new System.Text.StringBuilder();
        foreach (double[] pt in l) sb.Append(pt[0].ToString("0", CultureInfo.InvariantCulture)).Append(',').Append(pt[1].ToString("R", CultureInfo.InvariantCulture)).Append('\n');
        File.WriteAllText(path + ".tmp", sb.ToString()); File.Copy(path + ".tmp", path, true); File.Delete(path + ".tmp");
    }
}
public static class SSShare {
    public static List<double[]> Spans = new List<double[]>();
    // body from /v1/range: "minute data" lines; keeps points inside gaps (server ms, pairs a,b);
    // returns stock -> [[local ms, price]] using off = server time - local time
    public static Dictionary<string, List<double[]>> Merge(string body, double[] gaps, double off) {
        CultureInfo inv = CultureInfo.InvariantCulture;
        SortedDictionary<long, List<string>> rows = new SortedDictionary<long, List<string>>();
        foreach (string raw in body.Split('\n')) {
            string line = raw.TrimEnd('\r');
            if (line.Length < 3 || line.StartsWith("v1")) continue;
            int sp = line.IndexOf(' '); long m;
            if (sp < 1 || !long.TryParse(line.Substring(0, sp), out m)) continue;
            List<string> l; if (!rows.TryGetValue(m, out l)) { l = new List<string>(); rows[m] = l; }
            l.Add(line.Substring(sp + 1));
        }
        Dictionary<string, List<double[]>> outp = new Dictionary<string, List<double[]>>();
        Dictionary<string, double> prev = new Dictionary<string, double>();
        Spans = new List<double[]>();
        foreach (KeyValuePair<long, List<string>> kv in rows) {
            double minute = kv.Key;
            bool inGap = false;
            for (int g = 0; g + 1 < gaps.Length; g += 2) if (minute + 60000 > gaps[g] && minute < gaps[g + 1]) inGap = true;
            if (!inGap) continue;
            List<Dictionary<string, double[]>> parsed = new List<Dictionary<string, double[]>>();
            List<string> sids = new List<string>();
            foreach (string d0 in kv.Value) {
                string d = d0; int res = 1;
                if (d.StartsWith("r")) { int bar = d.IndexOf('|'); if (bar < 2 || !int.TryParse(d.Substring(1, bar - 1), out res) || res < 1) res = 1; d = d.Substring(bar + 1); }
                Dictionary<string, double[]> one = new Dictionary<string, double[]>();
                foreach (string part in d.Split(';')) {
                    int c = part.IndexOf(':'); if (c < 2) continue;
                    string sid = part.Substring(0, c); string[] vals = part.Substring(c + 1).Split(',');
                    double[] slots = new double[60];
                    for (int i = 0; i < vals.Length && i * res < 60; i++) { double v; if (vals[i].Length > 0 && double.TryParse(vals[i], NumberStyles.Float, inv, out v) && v > 0) slots[i * res] = v; }
                    one[sid] = slots; if (!sids.Contains(sid)) sids.Add(sid);
                }
                parsed.Add(one);
            }
            bool any = false;
            foreach (string sid in sids) {
                List<double[]> dest; if (!outp.TryGetValue(sid, out dest)) { dest = new List<double[]>(); outp[sid] = dest; }
                double pv; bool hasPrev = prev.TryGetValue(sid, out pv);
                for (int i = 0; i < 60; i++) {
                    List<double> vs = new List<double>();
                    foreach (Dictionary<string, double[]> one in parsed) { double[] sl; if (one.TryGetValue(sid, out sl) && sl[i] > 0) vs.Add(sl[i]); }
                    if (vs.Count == 0) continue;
                    double v;
                    if (vs.Count == 1) v = vs[0];
                    else if (vs.Count == 2) {
                        double a = vs[0], b = vs[1];
                        if (Math.Abs(a - b) <= 0.1 * Math.Max(a, b)) v = (a + b) / 2;
                        else if (hasPrev) v = Math.Abs(a - pv) <= Math.Abs(b - pv) ? a : b;
                        else continue;
                    } else { vs.Sort(); v = vs[vs.Count / 2]; }
                    pv = v; hasPrev = true;
                    double t = minute + i * 1000;
                    bool keep = false;
                    for (int g = 0; g + 1 < gaps.Length; g += 2) if (t >= gaps[g] && t < gaps[g + 1]) keep = true;
                    if (keep) { dest.Add(new double[] { t - off, v }); any = true; }
                }
                if (hasPrev) prev[sid] = pv;
            }
            if (any) {
                double a = minute, b = minute + 60000;
                if (Spans.Count > 0 && Spans[Spans.Count - 1][1] >= a) Spans[Spans.Count - 1][1] = b; else Spans.Add(new double[] { a, b });
            }
        }
        return outp;
    }
}
'@
function Read-Day($dk, $key, [double]$gap = 0) {
    $dir = Join-Path $HistDir $dk
    $own = Join-Path $dir ($key + '.csv'); $sh = Join-Path $dir ($key + '.shared.csv')
    if ($global:FastIO) { try { return , [SSData]::ReadMany([string[]]@($own, $sh), $gap) } catch { } }
    return , (Read-Series $own $gap)
}
function Read-Series($file, [double]$gap = 0) {
    if ($global:FastIO) { try { return , [SSData]::Read($file, $gap) } catch { } }
    $l = New-Series
    if (-not (Test-Path -LiteralPath $file)) { return , $l }
    $sty = [Globalization.NumberStyles]::Float; $lastKept = [double]::MinValue; $lastPt = $null
    foreach ($line in [IO.File]::ReadAllLines($file)) {
        $i = $line.IndexOf(','); if ($i -lt 1) { continue }
        $t = 0.0; $p = 0.0
        if ([double]::TryParse($line.Substring(0, $i), $sty, $Inv, [ref]$t) -and [double]::TryParse($line.Substring($i + 1), $sty, $Inv, [ref]$p)) {
            $lastPt = [double[]]@($t, $p)
            if ($gap -le 0 -or ($t - $lastKept) -ge $gap) { $l.Add($lastPt); $lastKept = $t }
        }
    }
    if ($lastPt -and $l.Count -and $l[$l.Count - 1][0] -lt $lastPt[0]) { $l.Add($lastPt) }
    return , $l
}
# day folders older than 30 days keep one high/low pair per 5 seconds instead of every update (saves disk space)
function Compact-Old {
    if (-not $global:FastIO) { return }
    $cut = (Get-Date).AddDays(-30).ToString('yyyy-MM-dd'); $n = 0
    foreach ($d in @(Get-ChildItem -LiteralPath $HistDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{4}-\d\d-\d\d$' -and $_.Name -lt $cut })) {
        $mark = Join-Path $d.FullName '.thin'; if (Test-Path -LiteralPath $mark) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $d.FullName -Filter '*.csv' -ErrorAction SilentlyContinue)) { if ($f.Name -ne 'trades.csv') { try { [SSData]::Thin($f.FullName, 5000) } catch { } } }
        try { [IO.File]::WriteAllText($mark, '5s') } catch { }; $n++
    }
    if ($n) { Say "Shrank $n old day(s) of price history (older than 30 days)." Gray }
}
function Read-Trades($file) {
    $out = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $file)) { return , $out }
    $sty = [Globalization.NumberStyles]::Float
    foreach ($line in [IO.File]::ReadAllLines($file)) {
        $a = $line.Split(','); if ($a.Length -lt 6) { continue }
        $t = 0.0; $q = 0.0; $p = 0.0
        if ([double]::TryParse($a[0], $sty, $Inv, [ref]$t) -and [double]::TryParse($a[3], $sty, $Inv, [ref]$q) -and [double]::TryParse($a[4], $sty, $Inv, [ref]$p)) { [void]$out.Add(@($t, $a[1], $a[2], $q, $p, $a[5])) }
    }
    return , $out
}
function Save-Daily {
    $o = [ordered]@{}
    foreach ($k in ($global:Daily.Keys | Sort-Object)) { $v = $global:Daily[$k]; $o[$k] = [ordered]@{ start = $v.start; last = $v.last; high = $v.high; low = $v.low } }
    [IO.File]::WriteAllText((Join-Path $DataDir 'daily.json'), ([pscustomobject]$o | ConvertTo-Json -Depth 4), $Utf8)
}
function Load-Saved {
    $d = Read-Json (Join-Path $DataDir 'daily.json')
    if ($d) { foreach ($p in $d.PSObject.Properties) { $global:Daily[$p.Name] = @{ start = (Num $p.Value.start); last = (Num $p.Value.last); high = (Num $p.Value.high); low = (Num $p.Value.low) } } }
    # move v1 files (prices-YYYY-MM-DD.csv with t,stock,price) into history/<day>/<stock>.csv
    foreach ($f in @(Get-ChildItem -LiteralPath $DataDir -Filter 'prices-*.csv' -ErrorAction SilentlyContinue)) {
        $day = $f.BaseName.Substring(7)
        $dir = Join-Path $HistDir $day; [void][IO.Directory]::CreateDirectory($dir)
        $by = @{}
        foreach ($line in [IO.File]::ReadAllLines($f.FullName)) {
            $a = $line.Split(','); if ($a.Length -ne 3) { continue }
            if (-not $by.ContainsKey($a[1])) { $by[$a[1]] = New-Object System.Text.StringBuilder }
            [void]$by[$a[1]].Append($a[0]).Append(',').Append($a[2]).Append("`n")
        }
        foreach ($k in $by.Keys) { [IO.File]::AppendAllText((Join-Path $dir ((SafeName $k) + '.csv')), $by[$k].ToString(), $Utf8) }
        Move-Item -LiteralPath $f.FullName -Destination ($f.FullName + '.moved') -Force
    }
    $global:DayKey = (Get-Date).ToString('yyyy-MM-dd')
    $dir = Join-Path $HistDir $global:DayKey
    $keys = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.csv' -ErrorAction SilentlyContinue)) {
        if ($f.Name -eq 'trades.csv') { $global:Trades = Read-Trades $f.FullName }
        else { $keys[($f.BaseName -replace '\.shared$', '')] = 1 }
    }
    foreach ($k in $keys.Keys) {
        $ser = Read-Day $global:DayKey $k 5000; $global:DayData[$k] = $ser
        if ($ser.Count) { $global:LastW[$k] = $ser[$ser.Count - 1] }
    }
}
# --------------------------------------------------------------------- shared tracking
# One market for all players. With sharing on, StockPilot sends the prices it records to the
# server and fills times your game was closed with prices other players recorded.
# Only stock prices are sent - never cash, shares, positions or anything about your account.
$ShareUrlDefault = 'https://stockpilot.alisaandhomiayt.workers.dev'
$ShareLookbackMs = 7 * 86400000.0
$ShareUpEvery = 5; $ShareFast = [bool]$env:SSBOT_SHAREFAST   # minutes between uploads (fast = testing)
$global:Http = $null
$global:Share = @{
    on = $true; url = ''; id = ''; off = 0.0; offKnown = $false
    buf = @{}; queue = (New-Object System.Collections.Generic.List[string]); req = $null
    nextUp = (Get-Date).AddSeconds(20); nextFill = (Get-Date).AddSeconds(15); nextStatus = (Get-Date).AddSeconds(25); nextSave = (Get-Date).AddMinutes(1)
    cover = (New-Object 'System.Collections.Generic.List[double[]]'); coverDirty = $false
    plan = (New-Object System.Collections.ArrayList); sent = 0; filledMs = 0.0; fails = 0; err = ''; latest = 0.0
}
function Share-Url { $u = "$($global:Share.url)"; if (-not $u) { $u = $ShareUrlDefault }; return $u.TrimEnd('/') }
function Share-Active { return [bool]($global:Share.on -and $global:FastIO -and (Share-Url)) }
function SrvNow { return (NowMs) + $global:Share.off }

# ---- which times we already have (recorded, or checked on the server): sorted [start, end] in server ms
function Cover-Merge {
    $c = $global:Share.cover; [SSData]::SortList($c)
    $m = New-Object 'System.Collections.Generic.List[double[]]'
    foreach ($iv in $c) {
        if ($m.Count -and $iv[0] -le ($m[$m.Count - 1][1] + 1000)) { if ($iv[1] -gt $m[$m.Count - 1][1]) { $m[$m.Count - 1][1] = $iv[1] } }
        else { $m.Add([double[]]@($iv[0], $iv[1])) }
    }
    $global:Share.cover = $m; $global:Share.coverDirty = $true
}
function Cover-Add([double]$a, [double]$b) {
    if (-not $global:FastIO -or $b -le $a) { return }
    $global:Share.cover.Add([double[]]@($a, $b)); Cover-Merge
}
function Cover-Extend([double]$t) {
    if (-not $global:FastIO) { return }
    $c = $global:Share.cover
    if ($c.Count) {
        $last = $c[$c.Count - 1]
        if ($t -ge $last[0] -and $t -le $last[1] + 25000) { if ($t -gt $last[1]) { $last[1] = $t; $global:Share.coverDirty = $true }; return }
    }
    Cover-Add $t ($t + 1000)
}
function Cover-Gaps([double]$from, [double]$to) {
    $gaps = New-Object System.Collections.ArrayList; $p = $from
    foreach ($iv in $global:Share.cover) {
        if ($iv[1] -le $p) { continue }
        if ($iv[0] -ge $to) { break }
        if ($iv[0] - $p -ge 2000) { [void]$gaps.Add([double[]]@($p, $iv[0])) }
        $p = [math]::Max($p, $iv[1])
    }
    if ($to - $p -ge 2000) { [void]$gaps.Add([double[]]@($p, $to)) }
    return , $gaps
}
function Cover-Load {
    if (-not $global:FastIO) { return }
    $f = Join-Path $DataDir 'coverage.txt'
    if (Test-Path -LiteralPath $f) {
        foreach ($line in [IO.File]::ReadAllLines($f)) {
            $a = $line.Split(','); $x = 0.0; $y = 0.0
            if ($a.Length -eq 2 -and [double]::TryParse($a[0], [Globalization.NumberStyles]::Float, $Inv, [ref]$x) -and [double]::TryParse($a[1], [Globalization.NumberStyles]::Float, $Inv, [ref]$y) -and $y -gt $x) { $global:Share.cover.Add([double[]]@($x, $y)) }
        }
    } else {
        # first run: work out what is already recorded from the saved day files (one stock per day is enough)
        $cut = (Get-Date).AddDays(-8).ToString('yyyy-MM-dd')
        foreach ($d in @(Get-ChildItem -LiteralPath $HistDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{4}-\d\d-\d\d$' -and $_.Name -ge $cut })) {
            $big = Get-ChildItem -LiteralPath $d.FullName -Filter '*.csv' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'trades.csv' -and $_.Name -notlike '*.shared.csv' } | Sort-Object Length -Descending | Select-Object -First 1
            if (-not $big) { continue }
            $a = $null; $b = $null
            foreach ($pt in [SSData]::ReadMany([string[]]@($big.FullName), 0)) {
                $t = $pt[0] + $global:Share.off
                if ($null -ne $b -and $t - $b -le 25000) { $b = $t } else { if ($null -ne $a) { $global:Share.cover.Add([double[]]@($a, ($b + 1000))) }; $a = $t; $b = $t }
            }
            if ($null -ne $a) { $global:Share.cover.Add([double[]]@($a, ($b + 1000))) }
        }
    }
    Cover-Merge
}
function Cover-Save {
    if (-not $global:FastIO -or -not $global:Share.coverDirty) { return }
    $old = (SrvNow) - $ShareLookbackMs - 86400000
    $sb = New-Object System.Text.StringBuilder
    foreach ($iv in $global:Share.cover) { if ($iv[1] -ge $old) { [void]$sb.Append($iv[0].ToString('0', $Inv)).Append(',').Append($iv[1].ToString('0', $Inv)).Append("`n") } }
    try { [IO.File]::WriteAllText((Join-Path $DataDir 'coverage.txt'), $sb.ToString(), $Utf8); $global:Share.coverDirty = $false } catch { }
}

# ---- sending: prices are collected per minute (60 one-second slots) and sent in batches
function Share-AddOne([double]$srvT, [string]$sid, [double]$p) {
    if ($srvT -le 0 -or $p -le 0 -or $sid -notmatch '^\$[A-Z0-9_]{1,16}$') { return }
    $min = [math]::Floor($srvT / 60000) * 60000; $sec = [int][math]::Floor(($srvT - $min) / 1000); if ($sec -gt 59) { $sec = 59 }
    $mb = $global:Share.buf[$min]; if ($null -eq $mb) { $mb = @{}; $global:Share.buf[$min] = $mb }
    $a = $mb[$sid]; if ($null -eq $a) { $a = New-Object 'double[]' 60; $mb[$sid] = $a }
    $a[$sec] = $p
}
function Share-Flush([double]$srvNow, [switch]$All) {
    foreach ($min in @($global:Share.buf.Keys | Sort-Object)) {
        if (-not $All -and ($min + 65000) -gt $srvNow) { continue }
        $mb = $global:Share.buf[$min]; $global:Share.buf.Remove($min)
        if (-not $global:Share.on) { continue }
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($sid in @($mb.Keys | Sort-Object)) {
            $a = $mb[$sid]; $any = $false; $vals = New-Object 'string[]' 60
            for ($i = 0; $i -lt 60; $i++) { if ($a[$i] -gt 0) { $vals[$i] = $a[$i].ToString('G7', $Inv); $any = $true } else { $vals[$i] = '' } }
            if ($any) { $parts.Add($sid + ':' + ($vals -join ',')) }
        }
        if ($parts.Count) { $global:Share.queue.Add(([long]$min).ToString($Inv) + ' ' + ($parts -join ';')) }
    }
    while ($global:Share.queue.Count -gt 2880) { $global:Share.queue.RemoveAt(0) }
}

# ---- web requests run in the background; Share-Step checks on them twice a second
function Http-Init {
    if ($global:Http) { return $true }
    try {
        try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch { }
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
        $h = New-Object System.Net.Http.HttpClientHandler
        $h.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
        $c = New-Object System.Net.Http.HttpClient($h); $c.Timeout = [TimeSpan]::FromSeconds(60)
        [void]$c.DefaultRequestHeaders.UserAgent.TryParseAdd("StockPilot/$Version")
        $global:Http = $c; return $true
    } catch { $global:Share.err = "web requests unavailable: $($_.Exception.Message)"; return $false }
}
function Http-Send($kind, $method, $url, $body, $meta) {
    if ($method -eq 'POST') { $t = $global:Http.PostAsync($url, (New-Object System.Net.Http.StringContent($body, $Utf8, 'text/plain'))) }
    else { $t = $global:Http.GetAsync($url) }
    $global:Share.req = @{ kind = $kind; task = $t; read = $null; status = 0; meta = $meta }
}
function Http-Poll {
    $r = $global:Share.req; if (-not $r) { return $null }
    if ($null -eq $r.read) {
        if (-not $r.task.IsCompleted) { return $null }
        if ($r.task.IsFaulted -or $r.task.IsCanceled) {
            $global:Share.req = $null; $msg = 'timed out'
            if ($r.task.Exception) { $msg = $r.task.Exception.GetBaseException().Message }
            return @{ kind = $r.kind; ok = $false; status = 0; text = ''; meta = $r.meta; err = $msg }
        }
        $resp = $r.task.Result; $r.status = [int]$resp.StatusCode; $r.read = $resp.Content.ReadAsStringAsync(); return $null
    }
    if (-not $r.read.IsCompleted) { return $null }
    $global:Share.req = $null
    $txt = ''; if (-not ($r.read.IsFaulted -or $r.read.IsCanceled)) { $txt = "$($r.read.Result)" }
    $err = ''; if ($r.status -ne 200) { $err = "error $($r.status): " + $txt.Substring(0, [math]::Min(80, $txt.Length)) }
    return @{ kind = $r.kind; ok = ($r.status -eq 200); status = $r.status; text = $txt; meta = $r.meta; err = $err }
}

# ---- receiving: hours (newest first) that still have gaps in the last 7 days
function Share-Plan([double]$srvNow) {
    $gaps = Cover-Gaps ($srvNow - $ShareLookbackMs) ($srvNow - 60000)
    $hours = New-Object System.Collections.ArrayList
    for ($i = $gaps.Count - 1; $i -ge 0; $i--) {
        $g = $gaps[$i]
        for ($h = [math]::Floor(($g[1] - 1) / 3600000); $h -ge [math]::Floor($g[0] / 3600000); $h--) { if (-not $hours.Contains($h)) { [void]$hours.Add($h) } }
    }
    $global:Share.plan.Clear()
    foreach ($h in @($hours | Select-Object -First 24)) {
        $H = $h * 3600000.0; $flat = New-Object System.Collections.Generic.List[double]
        foreach ($g in $gaps) { $a = [math]::Max($g[0], $H); $b = [math]::Min($g[1], $H + 3600000); if ($b -gt $a) { $flat.Add($a); $flat.Add($b) } }
        if ($flat.Count) { [void]$global:Share.plan.Add(@($H, $flat.ToArray())) }
    }
    if ($hours.Count -gt 24) { $global:Share.nextFill = (Get-Date).AddMinutes(1) } elseif ($ShareFast) { $global:Share.nextFill = (Get-Date).AddSeconds(30) } else { $global:Share.nextFill = (Get-Date).AddMinutes(10) }
}
function Share-Import($dict) {
    $hourAgo = (NowMs) - 3600000
    foreach ($sid in @($dict.Keys)) {
        $pts = $dict[$sid]
        if ($pts.Count -eq 0 -or $sid -notmatch '^\$[A-Z0-9_]{1,16}$') { continue }
        $key = SafeName $sid; $byDay = @{}
        $mem = $global:DayData[$key]; $memLast = [double]::MinValue; $memAdded = $false
        $live = $global:LiveData[$sid]; $liveAdded = $false
        foreach ($pt in $pts) {
            $dk = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$pt[0]).LocalDateTime.ToString('yyyy-MM-dd')
            $sb = $byDay[$dk]; if ($null -eq $sb) { $sb = New-Object System.Text.StringBuilder; $byDay[$dk] = $sb }
            [void]$sb.Append($pt[0].ToString('0', $Inv)).Append(',').Append($pt[1].ToString('R', $Inv)).Append("`n")
            if ($dk -eq $global:DayKey -and ($pt[0] - $memLast) -ge 5000) {
                if ($null -eq $mem) { $mem = New-Series; $global:DayData[$key] = $mem }
                $mem.Add($pt); $memLast = $pt[0]; $memAdded = $true
            }
            if ($pt[0] -ge $hourAgo) { if ($null -eq $live) { $live = New-Series; $global:LiveData[$sid] = $live }; $live.Add($pt); $liveAdded = $true }
        }
        foreach ($dk in $byDay.Keys) {
            $dir = Join-Path $HistDir $dk; [void][IO.Directory]::CreateDirectory($dir)
            try { [IO.File]::AppendAllText((Join-Path $dir ($key + '.shared.csv')), $byDay[$dk].ToString(), $Utf8) } catch { }
            $global:DayCache.Remove("$dk|$sid")
        }
        if ($memAdded) { [SSData]::SortList($mem) }
        if ($liveAdded) { [SSData]::SortList($live) }
        if (-not $global:Names.ContainsKey($sid)) { $global:Names[$sid] = $sid }
    }
}
function Share-Done($r) {
    $now = Get-Date
    if ($r.kind -eq 'up') {
        if ($r.ok) {
            $global:Share.queue.RemoveRange(0, [math]::Min($r.meta, $global:Share.queue.Count)); $global:Share.sent += $r.meta; $global:Share.fails = 0; $global:Share.err = ''
            if ($global:Share.queue.Count) { $global:Share.nextUp = $now.AddSeconds(2) } elseif ($ShareFast) { $global:Share.nextUp = $now.AddSeconds(15) } else { $global:Share.nextUp = $now.AddMinutes($ShareUpEvery) }
        } elseif ($r.status -eq 400 -or $r.status -eq 413) {
            $global:Share.queue.RemoveRange(0, [math]::Min($r.meta, $global:Share.queue.Count)); Say "Shared server refused some prices: $($r.err)" Yellow
            $global:Share.nextUp = $now.AddSeconds(30)
        } else {
            $global:Share.fails++; $global:Share.err = $r.err; $global:Share.nextUp = $now.AddMinutes([math]::Min(10, $global:Share.fails))
        }
    } elseif ($r.kind -eq 'status') {
        if ($r.ok) { $a = $r.text.Trim().Split(' '); if ($a.Length -ge 3) { $global:Share.latest = Num $a[2] }; $global:Share.err = '' } else { $global:Share.err = $r.err }
    } elseif ($r.kind -eq 'range') {
        if (-not $r.ok) { $global:Share.err = $r.err; $global:Share.plan.Clear(); $global:Share.nextFill = $now.AddMinutes(5); return }
        $global:Share.err = ''
        $flat = [double[]]$r.meta[1]
        $dict = [SSShare]::Merge($r.text, $flat, $global:Share.off)
        Share-Import $dict
        foreach ($sp in [SSShare]::Spans) {
            for ($g = 0; $g + 1 -lt $flat.Length; $g += 2) { $a = [math]::Max($sp[0], $flat[$g]); $b = [math]::Min($sp[1], $flat[$g + 1]); if ($b -gt $a) { $global:Share.filledMs += ($b - $a) } }
            $global:Share.cover.Add([double[]]@($sp[0], $sp[1]))
        }
        # times nobody shared: mark them checked once they are 15+ minutes old, so they are not asked for again
        $lim = (SrvNow) - 900000
        for ($g = 0; $g + 1 -lt $flat.Length; $g += 2) { $b = [math]::Min($flat[$g + 1], $lim); if ($b -gt $flat[$g]) { $global:Share.cover.Add([double[]]@($flat[$g], $b)) } }
        Cover-Merge
    }
}
function Share-Step {
    if (-not (Share-Active)) { return }
    if (-not (Http-Init)) { return }
    $now = Get-Date; $srvNow = SrvNow
    Share-Flush $srvNow
    if ($now -ge $global:Share.nextSave) { $global:Share.nextSave = $now.AddMinutes(1); Cover-Save }
    $res = Http-Poll
    if ($res) { Share-Done $res; return }
    if ($global:Share.req) { return }
    $u = Share-Url
    if ($global:Share.queue.Count -and $now -ge $global:Share.nextUp) {
        $n = [math]::Min(15, $global:Share.queue.Count)
        $body = "v1 $($global:Share.id)`n" + (($global:Share.queue.GetRange(0, $n)) -join "`n") + "`n"
        Http-Send 'up' 'POST' "$u/v1/upload" $body $n; return
    }
    if ($now -ge $global:Share.nextStatus) { $global:Share.nextStatus = $now.AddMinutes(30); Http-Send 'status' 'GET' "$u/v1/status" $null $null; return }
    if ($global:Share.plan.Count -eq 0 -and $now -ge $global:Share.nextFill) { Share-Plan $srvNow }
    if ($global:Share.plan.Count) {
        $it = $global:Share.plan[0]; $global:Share.plan.RemoveAt(0)
        $fl = [double[]]$it[1]; $from = [math]::Floor($fl[0] / 60000) * 60000; $to = [math]::Ceiling($fl[$fl.Length - 1] / 60000) * 60000
        Http-Send 'range' 'GET' ("$u/v1/range?from=" + $from.ToString('0', $Inv) + '&to=' + $to.ToString('0', $Inv)) $null $it
    }
}
function Share-Msg {
    if (-not $global:FastIO) { return "Not available on this computer (StockPilot's fast data helper couldn't load)." }
    if (-not (Share-Url)) { return 'Not set up yet: the shared server address is missing.' }
    if (-not $global:Share.on) { return 'Off. Prices from times your game was closed are not filled in.' }
    if ($global:Share.err) { return "Can't reach the shared server right now ($($global:Share.err)). Retrying automatically." }
    $f = $global:Share.filledMs / 60000; if ($f -ge 90) { $ft = ('{0:0.#} h' -f ($f / 60)) } else { $ft = ('{0:0} min' -f $f) }
    $msg = "On. This session: sent $($global:Share.sent) min of prices, filled $ft of gaps."
    if ($global:Share.latest -gt 0) {
        $ago = [math]::Max(0, ((SrvNow) - $global:Share.latest - 60000) / 60000)
        if ($ago -lt 3) { $msg += ' Other players are sharing right now.' } elseif ($ago -lt 120) { $msg += (' Latest shared prices: {0:0} min ago.' -f $ago) } else { $msg += (' Latest shared prices: {0:0.#} h ago.' -f ($ago / 60)) }
    }
    return $msg
}
function Share-SaveQueue {
    Share-Flush (SrvNow) -All
    $f = Join-Path $DataDir 'share-queue.txt'
    try { if ($global:Share.queue.Count) { [IO.File]::WriteAllLines($f, [string[]]$global:Share.queue.ToArray()) } elseif (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } } catch { }
}
function Share-LoadQueue {
    $f = Join-Path $DataDir 'share-queue.txt'
    if (Test-Path -LiteralPath $f) { try { foreach ($l in [IO.File]::ReadAllLines($f)) { if ($l) { $global:Share.queue.Add($l) } }; Remove-Item -LiteralPath $f -Force } catch { } }
}

# --------------------------------------------------------------------- skins
# Turns a picture into a Screen Stocks skin using the game's official skin files (mods\skins\*.json + image).
# StockPilot's own skins are named sp-<name>.json / sp-<name>.png; other skins are only listed and switched on/off.
$SkinThumbDir = Join-Path $DataDir 'skin-thumbs'
$AnimDir = Join-Path $DataDir 'anim'
$global:Anims = @{}
function Skins-Dir { return (Join-Path (Join-Path $GameDir 'mods') 'skins') }
function Get-Skins {
    $list = New-Object System.Collections.ArrayList
    $dir = Skins-Dir
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $j = Read-Json $f.FullName; if (-not $j) { continue }
        $ours = ($f.Name -like 'sp-*'); $thumb = ''
        if ($ours) { $tp = Join-Path $SkinThumbDir ($f.BaseName + '.jpg'); if (Test-Path -LiteralPath $tp) { $thumb = 'data:image/jpeg;base64,' + [Convert]::ToBase64String([IO.File]::ReadAllBytes($tp)) } }
        $nm = "$($j.displayName)"; if (-not $nm) { $nm = $f.BaseName }
        [void]$list.Add([pscustomobject]@{ file = $f.Name; name = $nm; enabled = ($j.enabled -ne $false); ours = [bool]$ours; anim = [bool]$global:Anims.ContainsKey($f.BaseName); thumb = $thumb })
    }
    return , $list
}
function New-Skin($meta, [string]$b64) {
    if (-not $GameDir -or -not (Test-Path -LiteralPath $GameDir)) { throw "Couldn't find the Screen Stocks folder." }
    $name = "$($meta.name)".Trim()
    if ($name -notmatch '^[A-Za-z0-9 _\-\.!]{1,40}$') { throw 'Use 1-40 letters, numbers, spaces or - _ . ! for the name.' }
    $slug = ($name.ToLower() -replace '[^a-z0-9]+', '-').Trim('-'); if (-not $slug) { $slug = 'skin' }
    $base = "sp-$slug"
    $bytes = [Convert]::FromBase64String($b64.Trim())
    if ($bytes.Length -lt 8 -or $bytes[0] -ne 0x89 -or $bytes[1] -ne 0x50 -or $bytes[2] -ne 0x4E -or $bytes[3] -ne 0x47) { throw 'The picture could not be converted.' }
    if ($bytes.Length -gt 40MB) { throw 'The picture is too big.' }
    $col = @{}
    foreach ($k in 'panels', 'buttons', 'glowColor', 'bg') { $v = "$($meta.$k)"; if ($v -notmatch '^#[0-9A-Fa-f]{6}$') { $v = '#2C2C35' }; $col[$k] = $v.ToUpper() }
    $frames = ($meta.frames -ne $false); $glow = ($meta.glow -eq $true)
    $dir = Skins-Dir; [void][IO.Directory]::CreateDirectory($dir)
    Anim-Remove $base; Remove-Item -LiteralPath (Join-Path $dir "$base.jpg") -Force -ErrorAction SilentlyContinue
    [IO.File]::WriteAllBytes((Join-Path $dir "$base.png"), $bytes)
    $vis = [ordered]@{ BGLevel = $false; BGMoney = $true; CenterBG = $false; DividendBG = $true; GraphBG = $true; InfoBG = $false; MainBG = $false; NewsBG = $true; SharesBG = $true; TickerBG = $true }
    $fr = @(); foreach ($k in $vis.Keys) { $fr += "        {`n            `"id`": `"$k`",`n            `"visible`": $(([string]$vis[$k]).ToLower())`n        }" }
    $tf = { param($b) if ($b) { 'true' } else { 'false' } }
    $json = "{`n" +
        "    `"enabled`": true,`n" +
        "    `"displayName`": `"$name`",`n" +
        "    `"backgroundImage`": `"`",`n" +
        "    `"backgroundSprite`": 3,`n" +
        "    `"uiImageColor`": `"#FFFFFF`",`n" +
        "    `"cameraBackgroundColor`": `"$($col.bg)FF`",`n" +
        "    `"usesOSFrame`": $(& $tf $frames),`n" +
        "    `"osFrameColor`": `"$($col.panels)EE`",`n" +
        "    `"osFrames`": [`n" + ($fr -join ",`n") + "`n    ],`n" +
        "    `"usesBloom`": $(& $tf $glow),`n" +
        "    `"bloomColor`": `"$($col.glowColor)`",`n" +
        "    `"bloomIntensity`": 1.5,`n" +
        "    `"bloomStrength`": 2.0,`n" +
        "    `"bloomSpill`": 0.0,`n" +
        "    `"usesSkinImage`": true,`n" +
        "    `"skinImage`": `"$base.png`",`n" +
        "    `"skinImageAspectRatio`": {`n        `"x`": 0.0,`n        `"y`": 0.0`n    },`n" +
        "    `"skinImageScale`": 1.0,`n" +
        "    `"buttonSprite`": -1,`n" +
        "    `"buttonColor`": `"$($col.buttons)FF`"`n}"
    [IO.File]::WriteAllText((Join-Path $dir "$base.json"), $json, $Utf8)
    $t = "$($meta.thumb)"
    if ($t.StartsWith('data:image/jpeg;base64,')) {
        try { $tb = [Convert]::FromBase64String($t.Substring(23)); if ($tb.Length -lt 600KB) { [void][IO.Directory]::CreateDirectory($SkinThumbDir); [IO.File]::WriteAllBytes((Join-Path $SkinThumbDir "$base.jpg"), $tb) } } catch { }
    }
    Say "Skin '$name' added to the game ($base.json)." Green
    return "$base.json"
}
function Set-SkinEnabled([string]$file, [bool]$on) {
    if ($file -notmatch '^[^\\/:*?"<>|]+\.json$') { throw 'bad file' }
    $p = Join-Path (Skins-Dir) $file; if (-not (Test-Path -LiteralPath $p)) { throw 'Skin not found.' }
    $txt = [IO.File]::ReadAllText($p)
    $v = 'false'; if ($on) { $v = 'true' }
    $new = [regex]::Replace($txt, '("enabled"\s*:\s*)(true|false)', ('${1}' + $v), 1)
    if ($new -ne $txt) { [IO.File]::WriteAllText($p, $new, $Utf8) }
    $bb = $file.Substring(0, $file.Length - 5); if ($global:Anims.ContainsKey($bb)) { $global:Anims[$bb].enabled = $on }
}
function Remove-Skin([string]$file) {
    if ($file -notmatch '^sp-[a-z0-9\-]+\.json$') { throw 'Only skins made with StockPilot can be deleted here.' }
    $base = $file.Substring(0, $file.Length - 5); $dir = Skins-Dir
    Anim-Remove $base
    foreach ($p in @((Join-Path $dir $file), (Join-Path $dir "$base.png"), (Join-Path $dir "$base.jpg"), (Join-Path $SkinThumbDir "$base.jpg"))) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    Say "Skin $base deleted." Gray
}
# ---- animated skins (GIF / video): frames stored in anim\<base>\NNNN.jpg, copied onto <base>.jpg while the game runs so the skin loops
function Build-SkinJson([string]$name, $col, [bool]$frames, [bool]$glow, [string]$img) {
    $vis = [ordered]@{ BGLevel = $false; BGMoney = $true; CenterBG = $false; DividendBG = $true; GraphBG = $true; InfoBG = $false; MainBG = $false; NewsBG = $true; SharesBG = $true; TickerBG = $true }
    $fr = @(); foreach ($k in $vis.Keys) { $fr += "        {`n            `"id`": `"$k`",`n            `"visible`": $(([string]$vis[$k]).ToLower())`n        }" }
    $tf = { param($b) if ($b) { 'true' } else { 'false' } }
    return "{`n" +
        "    `"enabled`": true,`n" +
        "    `"displayName`": `"$name`",`n" +
        "    `"backgroundImage`": `"`",`n" +
        "    `"backgroundSprite`": 3,`n" +
        "    `"uiImageColor`": `"#FFFFFF`",`n" +
        "    `"cameraBackgroundColor`": `"$($col.bg)FF`",`n" +
        "    `"usesOSFrame`": $(& $tf $frames),`n" +
        "    `"osFrameColor`": `"$($col.panels)EE`",`n" +
        "    `"osFrames`": [`n" + ($fr -join ",`n") + "`n    ],`n" +
        "    `"usesBloom`": $(& $tf $glow),`n" +
        "    `"bloomColor`": `"$($col.glowColor)`",`n" +
        "    `"bloomIntensity`": 1.5,`n" +
        "    `"bloomStrength`": 2.0,`n" +
        "    `"bloomSpill`": 0.0,`n" +
        "    `"usesSkinImage`": true,`n" +
        "    `"skinImage`": `"$img`",`n" +
        "    `"skinImageAspectRatio`": {`n        `"x`": 0.0,`n        `"y`": 0.0`n    },`n" +
        "    `"skinImageScale`": 1.0,`n" +
        "    `"buttonSprite`": -1,`n" +
        "    `"buttonColor`": `"$($col.buttons)FF`"`n}"
}
function Save-SkinThumb([string]$base, [string]$t) {
    if ($t -and $t.StartsWith('data:image/jpeg;base64,')) {
        try { $tb = [Convert]::FromBase64String($t.Substring(23)); if ($tb.Length -lt 600KB) { [void][IO.Directory]::CreateDirectory($SkinThumbDir); [IO.File]::WriteAllBytes((Join-Path $SkinThumbDir "$base.jpg"), $tb) } } catch { }
    }
}
function Anim-Remove([string]$base) {
    if ($global:Anims.ContainsKey($base)) { $global:Anims.Remove($base) }
    $ad = Join-Path $AnimDir $base
    if (Test-Path -LiteralPath $ad) { Remove-Item -LiteralPath $ad -Recurse -Force -ErrorAction SilentlyContinue }
}
function New-AnimSkin($meta) {
    if (-not $GameDir -or -not (Test-Path -LiteralPath $GameDir)) { throw "Couldn't find the Screen Stocks folder." }
    $name = "$($meta.name)".Trim()
    if ($name -notmatch '^[A-Za-z0-9 _\-\.!]{1,40}$') { throw 'Use 1-40 letters, numbers, spaces or - _ . ! for the name.' }
    $slug = ($name.ToLower() -replace '[^a-z0-9]+', '-').Trim('-'); if (-not $slug) { $slug = 'skin' }
    $base = "sp-$slug"
    $fps = [double]$meta.fps; if ($fps -le 0 -or $fps -gt 30) { $fps = 10 }
    $count = [int]$meta.count; if ($count -lt 1 -or $count -gt 400) { throw 'Too many frames.' }
    $col = @{}
    foreach ($k in 'panels', 'buttons', 'glowColor', 'bg') { $v = "$($meta.$k)"; if ($v -notmatch '^#[0-9A-Fa-f]{6}$') { $v = '#2C2C35' }; $col[$k] = $v.ToUpper() }
    $frames = ($meta.frames -ne $false); $glow = ($meta.glow -eq $true)
    $dir = Skins-Dir; [void][IO.Directory]::CreateDirectory($dir)
    Remove-Item -LiteralPath (Join-Path $dir "$base.png") -Force -ErrorAction SilentlyContinue
    Anim-Remove $base
    $ad = Join-Path $AnimDir $base; [void][IO.Directory]::CreateDirectory($ad)
    [IO.File]::WriteAllText((Join-Path $dir "$base.json"), (Build-SkinJson $name $col $frames $glow "$base.jpg"), $Utf8)
    Save-SkinThumb $base "$($meta.thumb)"
    [IO.File]::WriteAllText((Join-Path $ad 'meta.json'), (@{ fps = $fps; count = $count } | ConvertTo-Json -Compress), $Utf8)
    $global:Anims[$base] = @{ dir = $ad; count = 0; fps = $fps; idx = 0; nextAt = (Get-Date); enabled = $true; img = (Join-Path $dir "$base.jpg"); ready = $false }
    return $base
}
function Add-AnimFrame([string]$base, [int]$idx, [string]$b64) {
    $a = $global:Anims[$base]; if (-not $a) { throw 'Unknown skin.' }
    if ($idx -lt 0 -or $idx -gt 399) { throw 'bad frame' }
    $bytes = [Convert]::FromBase64String($b64.Trim())
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xFF -or $bytes[1] -ne 0xD8) { throw 'bad frame' }
    if ($bytes.Length -gt 8MB) { throw 'frame too big' }
    [IO.File]::WriteAllBytes((Join-Path $a.dir ('{0:0000}.jpg' -f $idx)), $bytes)
    if ($idx -eq 0) { try { [IO.File]::WriteAllBytes($a.img, $bytes) } catch { } }
}
function Finish-AnimSkin([string]$base, [int]$count) {
    $a = $global:Anims[$base]; if (-not $a) { throw 'Unknown skin.' }
    $have = @(Get-ChildItem -LiteralPath $a.dir -Filter '*.jpg' -ErrorAction SilentlyContinue).Count
    if ($have -lt 1) { throw 'No frames received.' }
    $a.count = [math]::Min($count, $have); $a.ready = $true; $a.idx = 0; $a.nextAt = Get-Date
    [IO.File]::WriteAllText((Join-Path $a.dir 'meta.json'), (@{ fps = $a.fps; count = $a.count } | ConvertTo-Json -Compress), $Utf8)
    $first = Join-Path $a.dir '0000.jpg'; if (Test-Path -LiteralPath $first) { try { [IO.File]::Copy($first, $a.img, $true) } catch { } }
    Say "Animated skin '$base' added ($($a.count) frames, loops)." Green
}
function Anim-Load {
    $global:Anims = @{}
    if (-not (Test-Path -LiteralPath $AnimDir)) { return }
    foreach ($d in @(Get-ChildItem -LiteralPath $AnimDir -Directory -ErrorAction SilentlyContinue)) {
        $base = $d.Name; $json = Join-Path (Skins-Dir) ($base + '.json'); if (-not (Test-Path -LiteralPath $json)) { continue }
        $meta = Read-Json (Join-Path $d.FullName 'meta.json'); if (-not $meta) { continue }
        $cnt = [int]$meta.count; if ($cnt -lt 1) { continue }
        $en = $true; $j = Read-Json $json; if ($j -and $j.enabled -eq $false) { $en = $false }
        $global:Anims[$base] = @{ dir = $d.FullName; count = $cnt; fps = [double]$meta.fps; idx = 0; nextAt = (Get-Date); enabled = $en; img = (Join-Path (Skins-Dir) ($base + '.jpg')); ready = $true }
    }
}
function Anim-Step {
    if ($global:Anims.Count -eq 0 -or -not $global:Connected) { return }
    $now = Get-Date
    foreach ($base in @($global:Anims.Keys)) {
        $a = $global:Anims[$base]
        if (-not $a.enabled -or -not $a.ready -or $a.count -lt 2 -or $a.fps -le 0 -or $now -lt $a.nextAt) { continue }
        $a.nextAt = $now.AddMilliseconds([math]::Max(40, 1000.0 / $a.fps))
        $a.idx = ($a.idx + 1) % $a.count
        $src = Join-Path $a.dir ('{0:0000}.jpg' -f $a.idx)
        try { if (Test-Path -LiteralPath $src) { [IO.File]::Copy($src, $a.img, $true) } } catch { }
    }
}

function Add-Trade($t, $sid, $act, $qty, $px, $src) {
    [void]$global:Trades.Add(@($t, $sid, $act, $qty, $px, $src))
    $name = $global:Names[$sid]; if (-not $name) { $name = $sid }
    $who = 'you'; $col = 'Gray'; if ($src -eq 'bot') { $who = 'bot'; $col = 'Green' }
    Say ('Trade: ' + $act.ToUpper() + ' ' + (Fmt-Short $qty) + ' ' + $name + ' @ ' + $px.ToString('0.###', $Inv) + " ($who)") $col
    try {
        $dir = Join-Path $HistDir $global:DayKey; [void][IO.Directory]::CreateDirectory($dir)
        [IO.File]::AppendAllText((Join-Path $dir 'trades.csv'), ($t.ToString('0', $Inv) + ',' + $sid + ',' + $act + ',' + $qty.ToString('R', $Inv) + ',' + $px.ToString('R', $Inv) + ',' + $src + "`n"), $Utf8)
    } catch { }
}
function Record($m) {
    $now = Get-Date; $t = NowMs
    $dk = $now.ToString('yyyy-MM-dd')
    if ($dk -ne $global:DayKey) { Flush-Writes; $global:DayKey = $dk; $global:DayData = @{}; $global:Trades = New-Object System.Collections.ArrayList; $global:NextRecord = [DateTime]::MinValue }
    $nwr = Get-NetWorth $m; $nw = [double]$nwr[0]; $global:NetWorth = $nw; $global:NetWorthEst = $nwr[1]
    $points = @()
    foreach ($s in @($m.stocks)) {
        if (-not $s -or $s.unlocked -eq $false) { continue }
        $points += , @("$($s.stockId)", (Num $s.price))
    }
    $cut = $t - 3600000
    foreach ($pt in $points) {
        Add-Point $global:LiveData $pt[0] $t $pt[1]
        $l = $global:LiveData[$pt[0]]; $drop = 0
        while ($drop -lt $l.Count -and $l[$drop][0] -lt $cut) { $drop++ }
        if ($drop -gt 0) { $l.RemoveRange(0, $drop) }
    }
    # trades: detect changes in what you own / have shorted (bot or by hand)
    $pos = @{}; foreach ($p in @($m.player.positions)) { if ($p) { $pos["$($p.stockId)"] = $p } }
    foreach ($s in @($m.stocks)) {
        if (-not $s) { continue }
        $sid = "$($s.stockId)"; $p = $pos[$sid]
        $o = 0.0; $sh = 0.0; if ($p) { $o = Num $p.sharesOwned; $sh = Num $p.sharesShorted }
        $prev = $global:PrevPos[$sid]; $global:PrevPos[$sid] = @($o, $sh)
        if ($null -eq $prev) { continue }
        $px = Num $s.price
        $src = 'you'; $lc = $global:LastCmdAt[$sid]; if ($lc -and ((Get-Date) - $lc).TotalSeconds -lt 8) { $src = 'bot' }
        if ($o -gt $prev[0]) { Add-Trade $t $sid 'buy' ($o - $prev[0]) $px $src } elseif ($o -lt $prev[0]) { Add-Trade $t $sid 'sell' ($prev[0] - $o) $px $src }
        if ($sh -gt $prev[1]) { Add-Trade $t $sid 'short' ($sh - $prev[1]) $px $src } elseif ($sh -lt $prev[1]) { Add-Trade $t $sid 'cover' ($prev[1] - $sh) $px $src }
    }
    $d = $global:Daily[$dk]
    if (-not $d) { $d = @{ start = $nw; last = $nw; high = $nw; low = $nw }; $global:Daily[$dk] = $d }
    $d.last = $nw; if ($nw -gt $d.high) { $d.high = $nw }; if ($nw -lt $d.low) { $d.low = $nw }
    # shared tracking: same prices, stamped with the game server's clock
    $srvT = Num $m.serverTimeMs
    if ($srvT -gt 0) {
        if (Share-Active) { foreach ($pt in $points) { Share-AddOne $srvT $pt[0] ([double]$pt[1]) } }
        Cover-Extend $srvT
    }
    # every price update goes into the history files (unchanged prices at most once per 10 s)
    foreach ($pt in $points) {
        $key = SafeName $pt[0]; $p = [double]$pt[1]
        $lw = $global:LastW[$key]
        if ($lw -and $lw[1] -eq $p -and ($t - $lw[0]) -lt 10000) { continue }
        $global:LastW[$key] = [double[]]@($t, $p)
        $sb = $global:WriteBuf[$key]; if ($null -eq $sb) { $sb = New-Object System.Text.StringBuilder; $global:WriteBuf[$key] = $sb }
        [void]$sb.Append($t.ToString('0', $Inv)).Append(',').Append($p.ToString('R', $Inv)).Append("`n")
        $mem = $global:DayData[$key]
        if ($null -eq $mem -or $mem.Count -eq 0 -or ($t - $mem[$mem.Count - 1][0]) -ge 5000) { Add-Point $global:DayData $key $t $p }
    }
    if ($now -ge $global:NextRecord) { $global:NextRecord = $now.AddSeconds(2); Flush-Writes }
    if ($now -ge $global:NextDaily) { $global:NextDaily = $now.AddSeconds(10); try { Save-Daily } catch { } }
}
function Flush-Writes {
    if ($global:WriteBuf.Count -eq 0 -or -not $global:DayKey) { return }
    $dir = Join-Path $HistDir $global:DayKey
    try { [void][IO.Directory]::CreateDirectory($dir) } catch { return }
    foreach ($k in @($global:WriteBuf.Keys)) {
        $sb = $global:WriteBuf[$k]; if ($sb.Length -eq 0) { continue }
        try { [IO.File]::AppendAllText((Join-Path $dir ($k + '.csv')), $sb.ToString(), $Utf8); [void]$sb.Clear() } catch { }
    }
}

function Backfill {
    $h = Read-Json (Join-Path $Export 'history.json')
    if ($null -eq $h) { return }
    $added = 0; $cut = (NowMs) - 3600000
    foreach ($st in @($h.stocks)) {
        if (-not $st) { continue }
        $sid = "$($st.stockId)"
        $pts = New-Series
        foreach ($x in @($st.samples)) { if ($x) { $pts.Add([double[]]@((Num $x.timeMs), (Num $x.price))) } }
        if ($pts.Count -eq 0) { continue }
        if (Share-Active) { foreach ($pt in $pts) { Share-AddOne $pt[0] $sid $pt[1] } }
        Cover-Add $pts[0][0] ($pts[$pts.Count - 1][0] + 1000)
        # live buffer (1m-1h charts)
        $live = $global:LiveData[$sid]
        $liveFirst = [double]::MaxValue; if ($live -and $live.Count) { $liveFirst = $live[0][0] }
        $pre = New-Series
        foreach ($pt in $pts) { if ($pt[0] -ge $cut -and $pt[0] -lt $liveFirst) { $pre.Add($pt) } }
        if ($pre.Count) { if ($live) { $live.InsertRange(0, $pre) } else { $global:LiveData[$sid] = $pre } }
        # saved day files: every sample, only newer than what is saved already
        $key = SafeName $sid
        $saved = $global:DayData[$key]; $last = 0.0
        if ($saved -and $saved.Count) { $last = $saved[$saved.Count - 1][0] }
        $byDay = @{}; $prevT = $last
        foreach ($pt in $pts) {
            if ($pt[0] -le $last) { continue }
            $global:LastW[$key] = $pt
            $dk = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$pt[0]).LocalDateTime.ToString('yyyy-MM-dd')
            if (-not $byDay.ContainsKey($dk)) { $byDay[$dk] = New-Object System.Text.StringBuilder }
            [void]$byDay[$dk].Append($pt[0].ToString('0', $Inv)).Append(',').Append($pt[1].ToString('R', $Inv)).Append("`n")
            if ($dk -eq $global:DayKey -and ($pt[0] - $prevT) -ge 5000) { Add-Point $global:DayData $key $pt[0] $pt[1]; $prevT = $pt[0] }
            $added++
        }
        foreach ($dk in $byDay.Keys) {
            $dir = Join-Path $HistDir $dk; [void][IO.Directory]::CreateDirectory($dir)
            try { [IO.File]::AppendAllText((Join-Path $dir ($key + '.csv')), $byDay[$dk].ToString(), $Utf8) } catch { }
            $global:DayCache.Remove("$dk|$sid")
        }
    }
    if ($added) { Say "Filled in $added earlier price points from the game's history (about the last 30 minutes)." Cyan }
}

# --------------------------------------------------------------------- tick
function Tick {
    Setup-Step
    if ($global:AutoGameAt -and (Get-Date) -ge $global:AutoGameAt) {
        $global:AutoGameAt = $null
        if ($global:SetupState -eq 'ok' -and -not (Game-Running)) { Say 'Opening Screen Stocks so prices keep being tracked.' Cyan; Launch-Game }
    }
    $t = $null
    try { $t = (Get-Item -LiteralPath $Rules).LastWriteTimeUtc } catch { }
    if ($t -and $t -ne $global:RulesTime) { Start-Sleep -Milliseconds 100; if (Apply-Rules) { Say 'Auto actions file changed - reloaded.' Cyan } }
    $stamp = 0L
    try { $fi = New-Object IO.FileInfo($MarketFile); if ($fi.Exists) { $stamp = $fi.LastWriteTimeUtc.Ticks + $fi.Length } } catch { }
    $mtMs = 0.0; if ($stamp -ne 0) { $mtMs = [double]([DateTimeOffset]$fi.LastWriteTimeUtc).ToUnixTimeMilliseconds() }
    if ($stamp -ne 0 -and $stamp -eq $global:MarketStamp -and $null -ne $global:LastSeq) {
        if (((Get-Date) - $global:LastSeqAt).TotalSeconds -gt 10) { $global:Connected = $false; $global:StatusMsg = 'Game not updating - is Screen Stocks open?' }
        return
    }
    $m = Read-Json $MarketFile
    if ($m) { $global:MarketStamp = $stamp }
    if ($null -eq $m -or -not $m.marketReady) {
        $global:Connected = $false; $global:StatusMsg = 'Waiting for the game - open Screen Stocks'
        return
    }
    $seq = "$($m.sequence)"
    if ($seq -eq $global:LastSeq) {
        if (((Get-Date) - $global:LastSeqAt).TotalSeconds -gt 10) { $global:Connected = $false; $global:StatusMsg = 'Game not updating - is Screen Stocks open?' }
        return
    }
    $first = ($null -eq $global:LastSeq)
    $global:LastSeq = $seq; $global:LastSeqAt = Get-Date; $global:Market = $m
    $st = Num $m.serverTimeMs
    if ($st -gt 0 -and $mtMs -gt 0) {
        $o = $st - $mtMs
        if ($global:Share.offKnown) { $global:Share.off = 0.9 * $global:Share.off + 0.1 * $o } else { $global:Share.off = $o; $global:Share.offKnown = $true }
    }
    $nb = $global:Names.Count
    foreach ($s in @($m.stocks)) { if ($s) { $sid = "$($s.stockId)"; if ($s.name) { $global:Names[$sid] = "$($s.name)" } else { $global:Names[$sid] = $sid } } }
    if ($first -or $global:Names.Count -ne $nb) { try { [IO.File]::WriteAllText((Join-Path $DataDir 'names.json'), ([pscustomobject]$global:Names | ConvertTo-Json -Compress), $Utf8) } catch { } }
    if ($first) {
        foreach ($res in @($m.commandResults)) { if ($res) { $global:Seen[($res | ConvertTo-Json -Compress -Depth 5)] = 1 } }
        $global:StatusMsg = 'Connecting...'
        try { Backfill } catch { Say "Couldn't read the game's price history: $($_.Exception.Message)" Yellow }
        return
    }
    $global:Connected = $true; $global:StatusMsg = 'Connected'
    Record $m
    if (-not $global:Paused -and $global:SetupState -eq 'ok') { Run-Cycle $m }
}

# ---------------------------------------------------------------------- api
function Get-State {
    $m = $global:Market
    $stocks = @(); $cash = $null; $buyIn = 0; $shortIn = 0
    if ($m) {
        $pos = @{}; foreach ($p in @($m.player.positions)) { if ($p) { $pos["$($p.stockId)"] = $p } }
        $now = Num $m.serverTimeMs
        $buyIn = [math]::Max(0, ((Num $m.player.nextBuyAtMs) - $now) / 1000)
        $shortIn = [math]::Max(0, ((Num $m.player.nextShortAtMs) - $now) / 1000)
        $cash = Num $m.player.cash
        foreach ($s in @($m.stocks)) {
            if (-not $s -or $s.unlocked -eq $false) { continue }
            $sid = "$($s.stockId)"; $p = $pos[$sid]; $px = Num $s.price
            $chg = $null; $live = $global:LiveData[$sid]
            if ($live -and $live.Count -gt 1 -and $live[0][1] -ne 0) { $chg = ($px - $live[0][1]) / $live[0][1] * 100 }
            $o = [ordered]@{ id = $sid; name = $global:Names[$sid]; price = $px; chg = $chg; owned = 0; shorted = 0; avgBuy = 0; avgShort = 0 }
            if ($p) { $o.owned = Num $p.sharesOwned; $o.shorted = Num $p.sharesShorted; $o.avgBuy = Num $p.averageBuyPrice; $o.avgShort = Num $p.averageShortPrice }
            $stocks += [pscustomobject]$o
        }
    } else {
        $ids = @{}
        foreach ($k in @($global:LiveData.Keys)) { if ($k -ne $NWID -and $k -like '$*') { $ids[$k] = 1 } }
        foreach ($k in @($global:DayData.Keys)) { if ($k -match '^_[A-Za-z0-9_]+$') { $ids['$' + $k.Substring(1)] = 1 } }
        foreach ($sid in @($ids.Keys | Sort-Object)) {
            $l = $global:LiveData[$sid]; if (-not $l -or -not $l.Count) { $l = $global:DayData[(SafeName $sid)] }
            $px = $null; if ($l -and $l.Count) { $px = $l[$l.Count - 1][1] }
            $nm = $global:Names[$sid]; if (-not $nm) { $nm = $sid }
            $stocks += [pscustomobject][ordered]@{ id = $sid; name = $nm; price = $px; chg = $null; owned = 0; shorted = 0; avgBuy = 0; avgShort = 0 }
        }
    }
    $nwChg = $null; $live = $global:LiveData[$NWID]
    if ($live -and $live.Count -gt 1 -and $live[0][1] -ne 0) { $nwChg = ($live[$live.Count - 1][1] - $live[0][1]) / [math]::Abs($live[0][1]) * 100 }
    $rules = @(); $status = @()
    foreach ($n in $global:Doc.rules) {
        $key = Rule-Key $n
        $fired = $global:Armed.ContainsKey($key) -and (-not $global:Armed[$key])
        $rules += [pscustomobject]$n
        $status += [pscustomobject]@{ fired = [bool]$fired; problem = (Check-Rule $n) }
    }
    $today = $global:Daily[(Get-Date).ToString('yyyy-MM-dd')]
    $tp = $null; $ts = $null
    if ($today) { $tp = $today.last - $today.start; $ts = $today.start }
    $tr = @()
    foreach ($x in @($global:Trades | Select-Object -Last 40)) {
        $nm = $global:Names[$x[1]]; if (-not $nm) { $nm = $x[1] }
        $tr += [pscustomobject]@{ t = $x[0]; stock = $nm; action = $x[2]; qty = $x[3]; price = $x[4]; src = $x[5] }
    }
    return [pscustomobject][ordered]@{
        version = $Version; connected = [bool]$global:Connected; status = $global:StatusMsg; paused = [bool]$global:Paused; dry = [bool]$global:Doc.dry
        setup = $global:SetupState; setupMsg = $global:SetupMsg; gameDir = $GameDir
        cash = $cash; netWorth = $global:NetWorth; netWorthEst = [bool]$global:NetWorthEst; nwChg = $nwChg; todayStart = $ts; todayProfit = $tp
        buyIn = $buyIn; shortIn = $shortIn; stocks = $stocks
        rules = $rules; ruleStatus = $status; rulesVersion = $global:RulesVersion; rulesError = $global:RulesError
        trades = $tr
        log = @($global:Log | Select-Object -Last 60 | ForEach-Object { [pscustomobject]$_ })
        pinned = [bool]$global:Settings.pin; pinAvailable = [bool]($global:PinOk -or ($IsWin -and (Test-Path -LiteralPath (Join-Path $Here 'StockPilot.exe')))); autostart = (Get-AutoStart); autostartAvailable = [bool]$IsWin; autoGame = [bool]$global:Settings.autoGame; awake = [bool]$global:Settings.awake
        shareOn = [bool]$global:Share.on; shareMsg = (Share-Msg); shareNeedsUrl = (-not $ShareUrlDefault); shareUrl = "$($global:Share.url)"
    }
}
function Get-Series($sid, [double]$from, [double]$to) {
    $out = New-Series
    if (($to - $from) -le 3601000) {
        $live = $global:LiveData[$sid]
        if ($live) { foreach ($pt in $live) { if ($pt[0] -ge $from) { $out.Add($pt) } } }
        return , $out
    }
    $todayKey = (Get-Date).ToString('yyyy-MM-dd')
    $days = @()
    if ($from -le 0) {
        $days = @(Get-ChildItem -LiteralPath $HistDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{4}-\d\d-\d\d$' } | Sort-Object Name | ForEach-Object { $_.Name })
    } else {
        $d = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$from).LocalDateTime.Date
        while ($d -le (Get-Date).Date) { $days += $d.ToString('yyyy-MM-dd'); $d = $d.AddDays(1) }
    }
    foreach ($dk in $days) {
        if ($dk -eq $todayKey) { continue }
        $ck = "$dk|$sid"; $ser = $global:DayCache[$ck]
        if ($null -eq $ser) { $ser = Read-Day $dk (SafeName $sid) 5000; $global:DayCache[$ck] = $ser }
        foreach ($pt in $ser) { if ($pt[0] -ge $from) { $out.Add($pt) } }
    }
    $mem = $global:DayData[(SafeName $sid)]; if ($mem) { foreach ($pt in $mem) { if ($pt[0] -ge $from) { $out.Add($pt) } } }
    $live = $global:LiveData[$sid]
    if ($live -and $live.Count) { $lp = $live[$live.Count - 1]; if ($out.Count -eq 0 -or $lp[0] -gt $out[$out.Count - 1][0]) { $out.Add($lp) } }
    return , $out
}
function Downsample($l, [int]$max) {
    if ($l.Count -le $max) { return , $l }
    $out = New-Series
    $buckets = [int]($max / 2); $n = $l.Count; $size = $n / $buckets
    for ($b = 0; $b -lt $buckets; $b++) {
        $s = [int][math]::Floor($b * $size); $e = [int][math]::Min($n, [math]::Floor(($b + 1) * $size))
        if ($e -le $s) { continue }
        $mi = $s; $ma = $s
        for ($i = $s + 1; $i -lt $e; $i++) { $v = $l[$i][1]; if ($v -lt $l[$mi][1]) { $mi = $i }; if ($v -gt $l[$ma][1]) { $ma = $i } }
        if ($mi -lt $ma) { $out.Add($l[$mi]); $out.Add($l[$ma]) } elseif ($ma -lt $mi) { $out.Add($l[$ma]); $out.Add($l[$mi]) } else { $out.Add($l[$mi]) }
    }
    $last = $l[$n - 1]; if ($out[$out.Count - 1][0] -ne $last[0]) { $out.Add($last) }
    return , $out
}
function Get-History($sid, $range) {
    $to = NowMs
    $spans = @{ '1m' = 60; '5m' = 300; '15m' = 900; '1h' = 3600; '6h' = 21600; '24h' = 86400 }
    if ($range -eq 'all') { $from = 0.0 } elseif ($spans.ContainsKey($range)) { $from = $to - $spans[$range] * 1000.0 } else { $range = '15m'; $from = $to - 900000.0 }
    $ser = Downsample (Get-Series $sid $from $to) 1600
    if ($range -eq 'all' -and $ser.Count) { $from = $ser[0][0] }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('{"stock":').Append((ConvertTo-Json -InputObject "$sid" -Compress)).Append(',"range":"').Append($range).Append('","from":').Append($from.ToString('0', $Inv)).Append(',"to":').Append($to.ToString('0', $Inv)).Append(',"points":[')
    $first = $true
    foreach ($pt in $ser) {
        if (-not $first) { [void]$sb.Append(',') }; $first = $false
        [void]$sb.Append('[').Append($pt[0].ToString('0', $Inv)).Append(',').Append($pt[1].ToString('R', $Inv)).Append(']')
    }
    [void]$sb.Append('],"trades":[')
    $trs = New-Object System.Collections.ArrayList
    if ($from -lt [double]([DateTimeOffset](Get-Date).Date).ToUnixTimeMilliseconds()) {
        foreach ($dir in @(Get-ChildItem -LiteralPath $HistDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
            if ($dir.Name -eq $global:DayKey) { continue }
            $ck = "$($dir.Name)|trades"; $tl = $global:DayCache[$ck]
            if ($null -eq $tl) { $tl = Read-Trades (Join-Path $dir.FullName 'trades.csv'); $global:DayCache[$ck] = $tl }
            foreach ($x in $tl) { [void]$trs.Add($x) }
        }
    }
    foreach ($x in $global:Trades) { [void]$trs.Add($x) }
    $first = $true
    foreach ($x in $trs) {
        if ($x[1] -ne $sid -or $x[0] -lt $from) { continue }
        if (-not $first) { [void]$sb.Append(',') }; $first = $false
        [void]$sb.Append('[').Append(([double]$x[0]).ToString('0', $Inv)).Append(',"').Append($x[2]).Append('",').Append(([double]$x[3]).ToString('R', $Inv)).Append(',').Append(([double]$x[4]).ToString('R', $Inv)).Append(',"').Append($x[5]).Append('"]')
    }
    $ab = 0.0; $as = 0.0; $ow = 0.0; $so = 0.0
    if ($global:Market) {
        foreach ($p in @($global:Market.player.positions)) { if ($p -and "$($p.stockId)" -eq $sid) { $ab = Num $p.averageBuyPrice; $as = Num $p.averageShortPrice; $ow = Num $p.sharesOwned; $so = Num $p.sharesShorted } }
    }
    [void]$sb.Append('],"avgBuy":').Append($ab.ToString('R', $Inv)).Append(',"avgShort":').Append($as.ToString('R', $Inv)).Append(',"owned":').Append($ow.ToString('R', $Inv)).Append(',"shorted":').Append($so.ToString('R', $Inv)).Append('}')
    return $sb.ToString()
}
function Get-DailyJson {
    $rows = @()
    foreach ($k in ($global:Daily.Keys | Sort-Object -Descending | Select-Object -First 30)) {
        $v = $global:Daily[$k]
        $rows += [pscustomobject][ordered]@{ date = $k; start = $v.start; last = $v.last; high = $v.high; low = $v.low; profit = ($v.last - $v.start) }
    }
    return (ConvertTo-Json -InputObject @($rows) -Depth 3 -Compress)
}
function Save-Settings { try { [IO.File]::WriteAllText((Join-Path $DataDir 'settings.json'), ([pscustomobject]@{ onTop = [bool]$global:Settings.pin; autoGame = [bool]$global:Settings.autoGame; awake = [bool]$global:Settings.awake; share = [bool]$global:Share.on; shareUrl = "$($global:Share.url)"; shareId = "$($global:Share.id)"; clockOff = [double]$global:Share.off } | ConvertTo-Json -Compress), $Utf8) } catch { } }
function Load-Settings {
    $st = Read-Json (Join-Path $DataDir 'settings.json')
    if ($st) {
        if ($st.onTop -eq $false) { $global:Settings.pin = $false }
        if ($st.autoGame -eq $false) { $global:Settings.autoGame = $false }
        if ($st.awake -eq $false) { $global:Settings.awake = $false }
        if ($st.share -eq $false) { $global:Share.on = $false }
        if ($st.shareUrl -and "$($st.shareUrl)" -match '^https?://[A-Za-z0-9.\-:]+$') { $global:Share.url = "$($st.shareUrl)" }
        if ("$($st.shareId)" -match '^[A-Za-z0-9-]{8,64}$') { $global:Share.id = "$($st.shareId)" }
        if ($null -ne $st.clockOff) { $global:Share.off = Num $st.clockOff }
    }
    if (-not $global:Share.id) { $global:Share.id = [guid]::NewGuid().ToString('N'); Save-Settings }
    $nm = Read-Json (Join-Path $DataDir 'names.json')
    if ($nm) { foreach ($p in $nm.PSObject.Properties) { $global:Names[$p.Name] = "$($p.Value)" } }
}
# keep the PC from going to sleep while StockPilot runs (the screen can still turn off)
function Set-Awake($on) {
    if (-not $IsWin) { return }
    try {
        if (-not $global:AwakeOk) { Add-Type -Namespace SSP -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);'; $global:AwakeOk = $true }
        if ($on) { [void][SSP.Power]::SetThreadExecutionState([uint32]2147483649) } else { [void][SSP.Power]::SetThreadExecutionState([uint32]2147483648) }
    } catch { Say "Couldn't change the sleep setting: $($_.Exception.Message)" Yellow }
}
function Parse-Query($q) {
    $h = @{}
    if ($q) {
        foreach ($kv in $q.Split('&')) {
            if (-not $kv) { continue }
            $i = $kv.IndexOf('=')
            if ($i -lt 0) { $h[[Uri]::UnescapeDataString($kv)] = '' }
            else { $h[[Uri]::UnescapeDataString($kv.Substring(0, $i).Replace('+', ' '))] = [Uri]::UnescapeDataString($kv.Substring($i + 1).Replace('+', ' ')) }
        }
    }
    return $h
}
function Respond($client, [int]$status, [string]$type, [string]$text) {
    $reason = 'OK'
    if ($status -eq 403) { $reason = 'Forbidden' } elseif ($status -eq 404) { $reason = 'Not Found' } elseif ($status -eq 500) { $reason = 'Internal Server Error' }
    $body = [Text.Encoding]::UTF8.GetBytes($text)
    $head = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status $reason`r`nContent-Type: $type; charset=utf-8`r`nContent-Length: $($body.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n")
    $st = $client.GetStream()
    $st.Write($head, 0, $head.Length)
    if ($body.Length) { $st.Write($body, 0, $body.Length) }
    $st.Flush()
}
function Handle-Request($client, $method, $target, $headers, $body) {
    $hh = "$($headers['host'])".ToLower()
    if ($hh -ne "localhost:$($global:Port)" -and $hh -ne "127.0.0.1:$($global:Port)") { Respond $client 403 'text/plain' 'forbidden'; return }
    $path = "$target"; $query = ''
    $qi = $path.IndexOf('?'); if ($qi -ge 0) { $query = $path.Substring($qi + 1); $path = $path.Substring(0, $qi) }
    $q = Parse-Query $query
    if ($method -eq 'GET') {
        if ($path -eq '/') { Respond $client 200 'text/html' ($PanelHtml.Replace('__TOKEN__', $global:Token)); return }
        if ($path -eq '/api/state') { Respond $client 200 'application/json' ((Get-State) | ConvertTo-Json -Depth 6 -Compress); return }
        if ($path -eq '/api/history') { Respond $client 200 'application/json' (Get-History "$($q['stock'])" "$($q['range'])"); return }
        if ($path -eq '/api/daily') { Respond $client 200 'application/json' (Get-DailyJson); return }
        if ($path -eq '/api/skins') { $sk = Get-Skins; Respond $client 200 'application/json' (ConvertTo-Json -InputObject ([object[]]$sk.ToArray()) -Depth 4 -Compress); return }
        Respond $client 404 'text/plain' 'not found'; return
    }
    if ($method -ne 'POST' -or $headers['x-token'] -ne $global:Token) { Respond $client 403 'text/plain' 'forbidden'; return }
    if ($path -eq '/api/skin') {
        # body: one line of JSON settings, then the PNG as base64 (too big for ConvertFrom-Json on Windows PowerShell)
        $res = [ordered]@{ ok = $true }
        try {
            $nl = $body.IndexOf("`n"); if ($nl -lt 2) { throw 'Bad upload.' }
            $res.file = New-Skin ($body.Substring(0, $nl) | ConvertFrom-Json) $body.Substring($nl + 1)
        } catch { $res.ok = $false; $res.error = $_.Exception.Message }
        Respond $client 200 'application/json' ([pscustomobject]$res | ConvertTo-Json -Compress); return
    }
    if ($path -eq '/api/skinanim') {
        $res = [ordered]@{ ok = $true }
        try { $res.base = New-AnimSkin ($body | ConvertFrom-Json) } catch { $res.ok = $false; $res.error = $_.Exception.Message }
        Respond $client 200 'application/json' ([pscustomobject]$res | ConvertTo-Json -Compress); return
    }
    if ($path -eq '/api/skinframe') {
        $res = [ordered]@{ ok = $true }
        try { $nl = $body.IndexOf("`n"); if ($nl -lt 1) { throw 'bad frame' }; $hh2 = $body.Substring(0, $nl).Trim().Split(' '); Add-AnimFrame $hh2[0] ([int]$hh2[1]) $body.Substring($nl + 1) } catch { $res.ok = $false; $res.error = $_.Exception.Message }
        Respond $client 200 'application/json' ([pscustomobject]$res | ConvertTo-Json -Compress); return
    }
    $data = $null; if ($body) { $data = $body | ConvertFrom-Json }
    $out = [ordered]@{ ok = $true }
    if ($path -eq '/api/rules') {
        $list = New-Object System.Collections.ArrayList
        foreach ($r in @($data.rules)) { $n = Normalize-Rule $r; if ($n) { [void]$list.Add($n) } }
        Save-Rules ($data.dry -eq $true) $list
        [void](Apply-Rules)
        $out.version = $global:RulesVersion
    } elseif ($path -eq '/api/pause') {
        $global:Paused = ($data.paused -eq $true)
        if ($global:Paused) { Say 'Bot paused - no trades until you resume.' Yellow } else { Say 'Bot resumed.' Green }
    } elseif ($path -eq '/api/pin') {
        $global:Settings.pin = ($data.on -eq $true); Save-Settings; $out.n = Do-Pin $global:Settings.pin
        if (-not $global:PinOk -and $IsWin) { $l = Join-Path $Here 'StockPilot.exe'; if (Test-Path -LiteralPath $l) { $arg = 'off'; if ($global:Settings.pin) { $arg = 'on' }; try { Start-Process -FilePath $l -ArgumentList @('/pin', $arg) } catch { } } }
    } elseif ($path -eq '/api/edit') {
        try {
            if ($IsWin) { Start-Process notepad.exe -ArgumentList ('"' + $Rules + '"') }
            elseif ($IsMac) { Start-Process 'open' -ArgumentList @('-t', $Rules) }
            else { Start-Process 'xdg-open' -ArgumentList $Rules }
        } catch { }
    } elseif ($path -eq '/api/skinset') {
        try { Set-SkinEnabled "$($data.file)" ($data.enabled -eq $true) } catch { $out.ok = $false; $out.error = $_.Exception.Message }
    } elseif ($path -eq '/api/skindel') {
        try { Remove-Skin "$($data.file)" } catch { $out.ok = $false; $out.error = $_.Exception.Message }
    } elseif ($path -eq '/api/skinanimdone') {
        try { Finish-AnimSkin "$($data.base)" ([int]$data.count) } catch { $out.ok = $false; $out.error = $_.Exception.Message }
    } elseif ($path -eq '/api/settings') {
        if ($null -ne $data.autoGame) { $global:Settings.autoGame = ($data.autoGame -eq $true) }
        if ($null -ne $data.awake) { $global:Settings.awake = ($data.awake -eq $true); Set-Awake $global:Settings.awake }
        if ($null -ne $data.share) { $global:Share.on = ($data.share -eq $true); $global:Share.err = '' }
        if ($null -ne $data.shareUrl) {
            $u = "$($data.shareUrl)".Trim().TrimEnd('/')
            if ($u -eq '' -or $u -match '^https?://[A-Za-z0-9.\-:]+$') { $global:Share.url = $u; $global:Share.err = ''; $global:Share.nextFill = Get-Date; $global:Share.nextStatus = Get-Date; $global:Share.nextUp = Get-Date }
        }
        Save-Settings
    } elseif ($path -eq '/api/autostart') {
        Set-AutoStart ($data.on -eq $true)
        $out.on = Get-AutoStart
    } elseif ($path -eq '/api/quit') {
        Say 'Bot stopped from the panel.' Yellow
        $global:Quit = $true
    } else { Respond $client 404 'text/plain' 'not found'; return }
    Respond $client 200 'application/json' ([pscustomobject]$out | ConvertTo-Json -Compress)
}
# tiny web server on 127.0.0.1 (plain TCP - needs no admin rights, unlike HttpListener on Windows)
$global:Pending = New-Object System.Collections.ArrayList
function Poll-Clients {
    while ($global:Listener.Pending()) {
        $c = $global:Listener.AcceptTcpClient()
        [void]$global:Pending.Add(@{ c = $c; buf = (New-Object System.IO.MemoryStream); t = Get-Date })
    }
    for ($i = $global:Pending.Count - 1; $i -ge 0; $i--) {
        $p = $global:Pending[$i]; $c = $p.c; $done = $false
        try {
            $st = $c.GetStream()
            while ($st.DataAvailable) {
                $tmp = New-Object byte[] 16384
                $n = $st.Read($tmp, 0, $tmp.Length); if ($n -le 0) { break }
                $p.buf.Write($tmp, 0, $n)
            }
            $bytes = $p.buf.ToArray()
            if ($bytes.Length) {
                $text = [Text.Encoding]::UTF8.GetString($bytes)
                $he = $text.IndexOf("`r`n`r`n")
                if ($he -ge 0) {
                    $lines = $text.Substring(0, $he).Split("`n")
                    $parts = $lines[0].Trim().Split(' ')
                    $headers = @{}
                    for ($k = 1; $k -lt $lines.Count; $k++) { $ci = $lines[$k].IndexOf(':'); if ($ci -gt 0) { $headers[$lines[$k].Substring(0, $ci).Trim().ToLower()] = $lines[$k].Substring($ci + 1).Trim() } }
                    $len = 0; if ($headers['content-length']) { $len = [int]$headers['content-length'] }
                    if ($len -gt 80MB) { Respond $c 403 'text/plain' 'too big'; $done = $true; throw 'too big' }
                    $hb = [Text.Encoding]::UTF8.GetByteCount($text.Substring(0, $he + 4))
                    if (($bytes.Length - $hb) -ge $len) {
                        $body = ''; if ($len -gt 0) { $body = [Text.Encoding]::UTF8.GetString($bytes, $hb, $len) }
                        if ($parts.Count -ge 2) {
                            try { Handle-Request $c $parts[0] $parts[1] $headers $body } catch { try { Respond $c 500 'text/plain' "$($_.Exception.Message)" } catch { } }
                        }
                        $done = $true
                    }
                }
            }
            if (-not $done -and ((Get-Date) - $p.t).TotalSeconds -gt 60) { $done = $true }
        } catch { $done = $true }
        if ($done) { try { $c.Close() } catch { }; $global:Pending.RemoveAt($i) }
    }
}

# ----------------------------------------------------------- window helpers
$PinCode = @'
using System; using System.Text; using System.Runtime.InteropServices;
public static class SSWin {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    public static int Focus(string prefix, bool top) {
        int n = 0;
        EnumWindows(delegate (IntPtr h, IntPtr l) {
            if (!IsWindowVisible(h)) return true;
            StringBuilder sb = new StringBuilder(256); GetWindowText(h, sb, 256);
            string t = sb.ToString();
            if ((t == prefix || t.StartsWith(prefix + " ")) && !t.Contains("Setup") && !t.Contains("Uninstall")) {
                if (IsIconic(h)) ShowWindow(h, 9);
                SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x0013);
                if (!top) SetWindowPos(h, new IntPtr(-2), 0, 0, 0, 0, 0x0013);
                BringWindowToTop(h); SetForegroundWindow(h); n++;
            }
            return true;
        }, IntPtr.Zero);
        return n;
    }
    public static int Count(string prefix) {
        int n = 0;
        EnumWindows(delegate (IntPtr h, IntPtr l) {
            if (!IsWindowVisible(h)) return true;
            StringBuilder sb = new StringBuilder(256); GetWindowText(h, sb, 256);
            string t = sb.ToString();
            if ((t == prefix || t.StartsWith(prefix + " ") || t.StartsWith("127.0.0.1:")) && !t.Contains("Setup") && !t.Contains("Uninstall")) n++;
            return true;
        }, IntPtr.Zero);
        return n;
    }
    public static int Pin(string prefix, bool on) {
        int n = 0;
        EnumWindows(delegate (IntPtr h, IntPtr l) {
            if (!IsWindowVisible(h)) return true;
            StringBuilder sb = new StringBuilder(256); GetWindowText(h, sb, 256);
            string t = sb.ToString(); if ((t == prefix || t.StartsWith(prefix + " ")) && !t.Contains("Setup") && !t.Contains("Uninstall")) { SetWindowPos(h, new IntPtr(on ? -1 : -2), 0, 0, 0, 0, 0x0013); n++; }
            return true;
        }, IntPtr.Zero);
        return n;
    }
}
'@
function AutoStartPath { if (-not $IsWin) { return $null }; return (Join-Path ([Environment]::GetFolderPath('Startup')) 'StockPilot.lnk') }
function Get-AutoStart { $p = AutoStartPath; return [bool]($p -and (Test-Path -LiteralPath $p)) }
function Set-AutoStart($on) {
    $p = AutoStartPath; if (-not $p) { return }
    $exe = Join-Path $Here 'StockPilot.exe'
    if ($on -and (Test-Path -LiteralPath $exe)) {
        $ws = New-Object -ComObject WScript.Shell; $l = $ws.CreateShortcut($p)
        $l.TargetPath = $exe; $l.Arguments = '/background'; $l.WorkingDirectory = $Here; $l.IconLocation = (Join-Path $Here 'icon.ico') + ',0'; $l.Save()
        Say 'StockPilot will start with Windows and record in the background.' Green
    } elseif (-not $on) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue; Say 'StockPilot will no longer start with Windows.' Yellow }
}
function Do-Pin($on) { if (-not $global:PinOk) { return 0 }; try { return [SSWin]::Pin('StockPilot', [bool]$on) } catch { return 0 } }
function Do-Focus { if (-not $global:PinOk) { return 0 }; try { return [SSWin]::Focus('StockPilot', [bool]$global:Settings.pin) } catch { return 0 } }
function Panel-Shown { if (-not $global:PinOk) { return $false }; try { return ([SSWin]::Count('StockPilot') -gt 0) } catch { return $false } }
function Open-Panel($url) {
    $w = 1240; $h = 800
    $app = @("--app=$url")
    if ($IsWin) {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
            $w = [math]::Min($w, $wa.Width - 40); $h = [math]::Min($h, $wa.Height - 40)
            $app += ('--window-position=' + ($wa.Left + [int](($wa.Width - $w) / 2)) + ',' + ($wa.Top + [int](($wa.Height - $h) / 2)))
        } catch { }
        $app += "--window-size=$w,$h"
        # try each installed Chromium browser as an app window and check a window really appears
        $pf86 = ${env:ProgramFiles(x86)}
        $cands = @(
            (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
            (Join-Path $pf86 'Google\Chrome\Application\chrome.exe'),
            (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'),
            (Join-Path $pf86 'Microsoft\Edge\Application\msedge.exe'),
            (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
            (Join-Path $env:ProgramFiles 'BraveSoftware\Brave-Browser\Application\brave.exe'),
            (Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\Application\brave.exe')
        ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
        foreach ($exe in $cands) {
            try { Start-Process -FilePath $exe -ArgumentList $app } catch { Say "Couldn't start $(Split-Path -Leaf $exe): $($_.Exception.Message)" Yellow; continue }
            if (-not $global:PinOk) { Say "Opened the panel with $(Split-Path -Leaf $exe)." Gray; return }
            for ($i = 0; $i -lt 32; $i++) { Start-Sleep -Milliseconds 250; if (Panel-Shown) { Say "Opened the panel with $(Split-Path -Leaf $exe)." Gray; [void](Do-Focus); return } }
            Say "$(Split-Path -Leaf $exe) didn't open a window - trying the next browser." Yellow
        }
        # Firefox / Tor Browser (no app window, so open a normal window)
        $ff = @(
            (Join-Path $env:ProgramFiles 'Mozilla Firefox\firefox.exe'),
            (Join-Path $pf86 'Mozilla Firefox\firefox.exe'),
            (Join-Path $env:LOCALAPPDATA 'Mozilla Firefox\firefox.exe'),
            (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Tor Browser\Browser\firefox.exe'),
            (Join-Path $env:LOCALAPPDATA 'Tor Browser\Browser\firefox.exe'),
            (Join-Path $env:APPDATA 'Tor Browser\Browser\firefox.exe')
        ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
        foreach ($exe in $ff) {
            try { Start-Process -FilePath $exe -ArgumentList @('-new-window', $url); Say "Opened the panel with $(Split-Path -Leaf (Split-Path -Parent $exe))." Gray; return } catch { }
        }
        # last resort: the default browser, as a normal tab
        try { Start-Process (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList ('"' + $url + '"'); Say 'Opened the panel in your default browser.' Gray }
        catch { Say "Open this in your browser: $url" Yellow }
        return
    }
    $app += "--window-size=$w,$h"
    if ($IsMac) {
        foreach ($b in @('Google Chrome', 'Microsoft Edge', 'Brave Browser', 'Chromium')) {
            if (Test-Path -LiteralPath "/Applications/$b.app") { try { Start-Process 'open' -ArgumentList (@('-na', $b, '--args') + $app); return } catch { } }
        }
        try { Start-Process 'open' -ArgumentList $url } catch { Say "Open this in your browser: $url" Yellow }
        return
    }
    foreach ($b in @('google-chrome', 'google-chrome-stable', 'chromium', 'chromium-browser', 'microsoft-edge', 'microsoft-edge-stable', 'brave-browser', 'brave', 'vivaldi')) {
        if (Get-Command $b -ErrorAction SilentlyContinue) { try { Start-Process $b -ArgumentList $app; return } catch { } }
    }
    try { Start-Process 'xdg-open' -ArgumentList $url } catch { Say "Open this in your browser: $url" Yellow }
}

# ----------------------------------------------------------------- the page
$PanelHtml = @'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>StockPilot</title>
<link rel="icon" type="image/svg+xml" sizes="any" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E%3Cdefs%3E%3ClinearGradient id='g' x1='0' y1='0' x2='1' y2='1'%3E%3Cstop offset='0' stop-color='%23ffba49'/%3E%3Cstop offset='1' stop-color='%23ff5418'/%3E%3C/linearGradient%3E%3C/defs%3E%3Crect width='64' height='64' rx='14.7' fill='url%28%23g%29'/%3E%3Cpath d='M12.2 44.2 26.2 30.1 33.9 37.8 51.2 19.8' fill='none' stroke='%23fff' stroke-width='6.1' stroke-linecap='round' stroke-linejoin='round'/%3E%3Cpath d='M38.4 19.8H51.2V32.6' fill='none' stroke='%23fff' stroke-width='6.1' stroke-linecap='round' stroke-linejoin='round'/%3E%3Ccircle cx='44.8' cy='46.7' r='2.9' fill='%23fff' fill-opacity='.85'/%3E%3Ccircle cx='51.8' cy='39.7' r='1.9' fill='%23fff' fill-opacity='.85'/%3E%3Ccircle cx='38.4' cy='52.5' r='1.6' fill='%23fff' fill-opacity='.85'/%3E%3C/svg%3E">
<link rel="icon" type="image/png" sizes="192x192" href="data:image/png;base64,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">
<style>
:root{--bg:#141518;--panel:#18191d;--panel2:#1f2126;--line:#2a2c33;--grid:#202228;--text:#ecebe7;--text2:#b9b8b1;--muted:#7f7e79;--up:#86e08f;--down:#f07178;--blue:#4f8ff7;--orange:#f0a35e;--aqua:#2fc79a;--warn:#fab219;--brand:#ff7a1f;--brand2:#ffb347;--mono:"Cascadia Mono","Cascadia Code",Consolas,"SF Mono",Menlo,"DejaVu Sans Mono",monospace}
*{box-sizing:border-box}
html,body{margin:0;height:100%;background:var(--bg);color:var(--text);font:13px/1.4 "Segoe UI Variable","Segoe UI",-apple-system,BlinkMacSystemFont,system-ui,sans-serif}
body{display:flex;flex-direction:column}
button,input,select{font:inherit;color:inherit}
.m{font-family:var(--mono);font-variant-numeric:tabular-nums}
.bar{display:flex;align-items:center;gap:10px;padding:7px 12px;border-bottom:1px solid var(--line);background:var(--panel);flex-wrap:wrap}
.brand{display:flex;align-items:center;gap:8px;font-weight:700;white-space:nowrap}
.brand img{width:22px;height:22px;display:block}
.conn{display:flex;align-items:center;gap:6px;color:var(--text2);font-size:12px;min-width:0;max-width:280px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.dot{width:7px;height:7px;border-radius:50%;background:var(--muted);flex:none}.dot.on{background:var(--up)}.dot.warn{background:var(--warn)}
.kpis{display:flex;gap:16px;margin-left:auto;align-items:center}
.kpi .l{font-size:10px;color:var(--muted);text-transform:uppercase;letter-spacing:.06em}.kpi .v{font-size:13.5px;font-weight:600}
.seg{display:flex;background:var(--panel2);border:1px solid var(--line);border-radius:8px;padding:2px;gap:2px}
.seg button{border:0;background:none;padding:3px 9px;border-radius:6px;cursor:pointer;color:var(--muted);font-size:12px}
.seg button:hover{color:var(--text)}
.seg button.sel{background:#2c2f37;color:var(--text);box-shadow:inset 0 0 0 1px #4a4d57}
.seg button.sel.live{background:#1e4a26;color:#d9f7dc;box-shadow:inset 0 0 0 1px #3e8a4a}
.seg button.sel.prac{background:#4a3b12;color:#fde7b0;box-shadow:inset 0 0 0 1px #8a6d1e}
.ib{border:1px solid var(--line);background:var(--panel2);border-radius:8px;padding:4px 10px;cursor:pointer;color:var(--text2);font-size:12px;white-space:nowrap}
.ib:hover{color:var(--text);border-color:#3a3d46}.ib.on{border-color:var(--blue);color:var(--text)}.ib.stop:hover{border-color:var(--down);color:var(--down)}
.banner{display:none;padding:8px 12px;background:#3b3110;border-bottom:1px solid #6b5a1c;color:#fde7b0}.banner.err{background:#3a1717;border-color:#6b2a2a;color:#f5c2c2}
.ticker{display:flex;gap:6px;padding:7px 12px;overflow-x:auto;border-bottom:1px solid var(--line);background:var(--bg)}
.tk{flex:none;border:1px solid var(--line);background:var(--panel);border-radius:8px;padding:4px 10px;cursor:pointer;text-align:left}
.tk:hover{border-color:#3a3d46}.tk.sel{border-color:var(--brand);box-shadow:inset 0 0 0 1px var(--brand)}
.tk .n{font-weight:700;font-size:12px}.tk .p{font-size:11.5px;color:var(--text2)}.tk .c{font-size:11px;margin-left:6px}
.up{color:var(--up)}.down{color:var(--down)}
.main{flex:1;display:grid;grid-template-columns:minmax(0,1fr) 380px;min-height:0}
.chart{display:flex;flex-direction:column;min-width:0;min-height:0;border-right:1px solid var(--line)}
.chead{display:flex;align-items:center;gap:12px;padding:10px 12px 4px;flex-wrap:wrap}
.sym{font-weight:800;font-size:18px}.px{font-size:22px;font-weight:600}
.pill{font-size:11.5px;border-radius:6px;padding:2px 7px;font-weight:600}
.pill.up{background:#1e3a23;color:var(--up)}.pill.down{background:#3d1c20;color:var(--down)}
.ranges{margin-left:auto}
.cbox{position:relative;flex:1;min-height:340px;cursor:crosshair}
canvas{position:absolute;inset:0;width:100%;height:100%;display:block}
.readout{position:absolute;left:10px;top:4px;font-size:12px;color:var(--muted);pointer-events:none;white-space:nowrap}.readout b{color:var(--text);margin-left:14px}
.legend{display:flex;gap:14px;padding:4px 12px 8px;font-size:11.5px;color:var(--muted);flex-wrap:wrap}
.legend span{display:flex;align-items:center;gap:5px}.legend i{width:14px;height:0;border-top:2px dashed}
.side{display:flex;flex-direction:column;min-width:0;min-height:0;background:var(--panel)}
nav{display:flex;border-bottom:1px solid var(--line)}
nav button{flex:1;border:0;background:none;padding:9px 0;cursor:pointer;color:var(--muted);border-bottom:2px solid transparent;font-weight:600}
nav button.sel{color:var(--text);border-color:var(--brand)}
.drop{border:1.5px dashed var(--line);border-radius:10px;padding:22px 10px;text-align:center;line-height:1.7}
.drop.over{border-color:var(--brand);background:rgba(255,140,40,.06)}
.clr{display:flex;align-items:center;gap:6px}.clr input{width:30px;height:22px;border:1px solid var(--line);border-radius:5px;background:none;padding:0;cursor:pointer}
.skrow{display:flex;align-items:center;gap:10px;padding:8px 0;border-top:1px solid var(--line)}.skrow:first-child{border-top:0}
.skrow img,.skrow .ph{width:64px;height:36px;object-fit:cover;border-radius:5px;flex:none;background:var(--panel2)}
.skrow .nm{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.tabs{flex:1;overflow:auto;padding:12px}
.tab{display:none}.tab.sel{display:block}
.card{background:var(--panel2);border:1px solid var(--line);border-radius:10px;padding:10px;margin-bottom:10px}
h3{margin:0 0 8px;font-size:11px;font-weight:600;color:var(--muted);text-transform:uppercase;letter-spacing:.06em}
select,input[type=number],input[type=text]{background:var(--bg);border:1px solid var(--line);border-radius:7px;padding:4px 6px;min-width:0}
select:focus,input:focus{outline:2px solid var(--blue);outline-offset:-1px}
.row{display:flex;align-items:center;gap:6px;flex-wrap:wrap}
.t{color:var(--muted)}
.btn{border:0;border-radius:8px;padding:6px 12px;cursor:pointer;background:linear-gradient(135deg,var(--brand2),var(--brand));color:#1d1004;font-weight:700}
.btn.ghost{background:var(--panel2);color:var(--text);border:1px solid var(--line)}
.rule{background:var(--panel2);border:1px solid var(--line);border-radius:10px;padding:9px 10px;margin-bottom:8px}
.rule.off{opacity:.55}
.rule .r1,.rule .r2{display:flex;align-items:center;gap:6px;flex-wrap:wrap}.rule .r2{margin-top:6px}
.rule .r3{display:flex;justify-content:space-between;gap:8px;margin-top:7px;font-size:12px;color:var(--muted)}
.pct{width:56px}.price{width:92px}.stk{max-width:116px}
.act{font-weight:600}.act-buy,.act-cover{color:#8be3c3}.act-sell,.act-short{color:#f4a7ab}
.x{margin-left:auto;border:0;background:none;color:var(--muted);font-size:18px;cursor:pointer;line-height:1;padding:0 4px}.x:hover{color:var(--down)}
.rep{font-size:12px;color:var(--muted);display:flex;align-items:center;gap:4px;margin-left:auto}
.st{border-radius:20px;padding:1px 8px;background:var(--bg);color:var(--text2);white-space:nowrap}
.st.go{background:#123a2c;color:#9fe2c6}.st.done{background:#1c2c45;color:#a9c8f2}.st.bad{background:#4a1d1d;color:#f5b5b5}
.sw{position:relative;width:32px;height:18px;flex:none}.sw input{opacity:0;width:0;height:0}
.sw span{position:absolute;inset:0;background:#3a3c45;border-radius:20px;cursor:pointer;transition:.15s}
.sw span:before{content:"";position:absolute;width:14px;height:14px;left:2px;top:2px;background:#fff;border-radius:50%;transition:.15s}
.sw input:checked+span{background:var(--brand)}.sw input:checked+span:before{transform:translateX(14px)}
.save{font-size:12px;color:var(--muted);display:flex;justify-content:space-between;align-items:center;margin:4px 2px 10px}
.link{background:none;border:0;color:#8fb8ee;cursor:pointer;padding:0}
.empty{color:var(--muted);text-align:center;padding:16px 8px}
.log{font-size:12px}.log div{display:flex;gap:8px;padding:3px 0;border-bottom:1px solid #24262d}
.log .tm{color:var(--muted);flex:none}.log .ok{color:#9fe2c6}.log .err2{color:#f5b5b5}.log .warn{color:#f3d58a}.log .info{color:#a9c8f2}.log .dim{color:var(--text2)}
.hero{font-size:28px;font-weight:700;margin:2px 0}
.bars{display:flex;align-items:stretch;gap:2px;height:140px;position:relative;margin-top:6px}
.bar2{flex:1;position:relative}.bar2 i{position:absolute;left:0;right:0}
.zero{position:absolute;left:0;right:0;height:1px;background:#3a3c45}
.blabels{display:flex;gap:2px;font-size:10px;color:var(--muted);margin-top:3px}.blabels span{flex:1;text-align:center}
.tip{position:absolute;pointer-events:none;background:#0b0c0f;border:1px solid var(--line);border-radius:8px;padding:5px 8px;font-size:12px;display:none;white-space:nowrap;z-index:3}
table{width:100%;border-collapse:collapse;font-size:12px}
td,th{padding:5px 4px;text-align:right;border-bottom:1px solid #24262d}th{color:var(--muted);font-weight:500}td:first-child,th:first-child{text-align:left}
.cdisp{background:var(--bg);border:1px solid var(--line);border-radius:10px;padding:8px 10px;margin-bottom:8px}
.cdisp input{width:100%;background:none;border:0;font-size:15px;color:var(--text2);padding:0;outline:none}
.cres{font-size:24px;font-weight:700;text-align:right;min-height:32px;word-break:break-all}.cres small{display:block;font-size:12px;font-weight:400;color:var(--muted)}
.chips{display:flex;gap:6px;flex-wrap:wrap;margin-bottom:8px}
.chip{border:1px solid var(--line);background:var(--panel2);border-radius:8px;padding:4px 8px;cursor:pointer;text-align:left;font-size:12px}
.keys{display:grid;grid-template-columns:repeat(4,1fr);gap:6px}
.keys button{border:1px solid var(--line);background:var(--panel2);border-radius:9px;padding:9px 0;font-size:15px;cursor:pointer}
.keys button:hover{background:#262830}.keys .op{color:#8fb8ee}.keys .eq{background:var(--brand);border-color:var(--brand);color:#1d1004;font-weight:700}
.helper{display:grid;grid-template-columns:1fr 1fr;gap:6px 8px;align-items:center}.helper input{width:100%}
.out{display:grid;grid-template-columns:repeat(3,1fr);gap:6px;margin-top:8px}
.out div,.gs div{background:var(--bg);border-radius:8px;padding:5px 7px}.out .l{font-size:11px;color:var(--muted)}.out .v{font-weight:600}
.over{position:fixed;inset:0;background:rgba(10,11,13,.92);display:none;align-items:center;justify-content:center;text-align:center;z-index:9;font-size:15px;color:var(--text2)}
@media (max-width:1000px){.main{grid-template-columns:1fr}.chart{border-right:0;border-bottom:1px solid var(--line);min-height:460px}.kpis{margin-left:0;width:100%;order:9}}
</style></head><body>
<div class="bar">
  <div class="brand"><img src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E%3Cdefs%3E%3ClinearGradient id='g' x1='0' y1='0' x2='1' y2='1'%3E%3Cstop offset='0' stop-color='%23ffba49'/%3E%3Cstop offset='1' stop-color='%23ff5418'/%3E%3C/linearGradient%3E%3C/defs%3E%3Crect width='64' height='64' rx='14.7' fill='url%28%23g%29'/%3E%3Cpath d='M12.2 44.2 26.2 30.1 33.9 37.8 51.2 19.8' fill='none' stroke='%23fff' stroke-width='6.1' stroke-linecap='round' stroke-linejoin='round'/%3E%3Cpath d='M38.4 19.8H51.2V32.6' fill='none' stroke='%23fff' stroke-width='6.1' stroke-linecap='round' stroke-linejoin='round'/%3E%3Ccircle cx='44.8' cy='46.7' r='2.9' fill='%23fff' fill-opacity='.85'/%3E%3Ccircle cx='51.8' cy='39.7' r='1.9' fill='%23fff' fill-opacity='.85'/%3E%3Ccircle cx='38.4' cy='52.5' r='1.6' fill='%23fff' fill-opacity='.85'/%3E%3C/svg%3E" alt="" width="22" height="22">StockPilot</div>
  <span class="conn"><span class="dot" id="dot"></span><span id="status">Starting...</span></span>
  <div class="kpis">
    <div class="kpi"><div class="l">Cash</div><div class="v m" id="cash">-</div></div>
    <div class="kpi"><div class="l" id="nwl">Net worth</div><div class="v m" id="nw">-</div></div>
    <div class="kpi"><div class="l">Today</div><div class="v m" id="today">-</div></div>
    <div class="kpi"><div class="l">Buy</div><div class="v m" id="cdb">-</div></div>
    <div class="kpi"><div class="l">Short</div><div class="v m" id="cds">-</div></div>
  </div>
  <div class="seg" id="mode"><button data-m="prac">Practice</button><button data-m="live">Live</button></div>
  <button class="ib" id="pause">Pause</button>
  <button class="ib" id="pin" title="Keep this window on top of the game" style="display:none">Pin on top</button>
  <button class="ib stop" id="stop" title="Stop the bot">Stop</button>
</div>
<div class="banner" id="banner"></div>
<div class="ticker" id="ticker"></div>
<div class="main">
  <section class="chart">
    <div class="chead">
      <span class="sym" id="sym">-</span><span class="px m" id="px">-</span><span class="pill m" id="chg"></span>
      <div class="seg ranges" id="range"><button data-r="1m">1m</button><button data-r="5m">5m</button><button data-r="15m" class="sel">15m</button><button data-r="1h">1h</button><button data-r="6h">6h</button><button data-r="24h">24h</button><button data-r="all">All</button></div>
      <button class="ib" id="csv">Export CSV...</button>
    </div>
    <div class="cbox" id="cbox"><canvas id="cv"></canvas><div class="readout m" id="readout"></div></div>
    <div class="legend" id="legend"></div>
  </section>
  <aside class="side">
    <nav><button data-t="rules" class="sel">Auto actions</button><button data-t="profit">Profit</button><button data-t="calc">Calc</button><button data-t="skin">Skin</button><button data-t="log">Activity</button></nav>
    <div class="tabs">
      <section class="tab sel" id="t-rules">
        <div class="card"><h3>Buy low, sell high</h3>
          <div class="row"><select id="qaStock" class="stk"></select><span class="t">buy under</span><input id="qaBuy" class="price m" type="number" step="any" placeholder="price"></div>
          <div class="row" style="margin-top:6px"><span class="t">with</span><input id="qaPct" class="pct m" type="number" min="1" max="100" value="100"><span class="t">% cash, sell all over</span><input id="qaSell" class="price m" type="number" step="any" placeholder="price"></div>
          <div class="row" style="margin-top:8px;justify-content:flex-end"><button class="btn" id="qaAdd">Add both</button></div>
        </div>
        <div id="rules"></div>
        <div class="save"><button class="btn ghost" id="addRule">+ Add auto action</button><span id="saved"></span><button class="link" id="edit">Edit file</button></div>
      </section>
      <section class="tab" id="t-skin">
        <div class="card"><h3>Make a skin from a picture, GIF or video</h3>
          <div class="drop" id="drop"><b>Drop a picture, GIF or video here</b><br><span class="t">or</span> <button class="link" id="skinpick">choose a file</button><input type="file" id="skinfile" accept="image/png,image/jpeg,image/webp,image/bmp,image/gif,video/mp4,video/webm,video/quicktime" style="display:none"></div>
          <div id="skinform" style="display:none">
            <img id="skinprev" alt="" style="width:100%;border-radius:8px;margin-top:10px;display:block">
            <div class="t" id="skinanim" style="margin-top:6px;display:none"></div>
            <div class="row" style="margin-top:10px"><span class="t">Name</span><input type="text" id="skinname" maxlength="40" style="flex:1"></div>
            <div class="row" style="margin-top:8px;gap:14px;flex-wrap:wrap"><label class="t clr">Panels <input type="color" id="skinpanels"></label><label class="t clr">Buttons <input type="color" id="skinbuttons"></label><label class="t clr">Glow <input type="color" id="skinglowc"></label></div>
            <label class="row" style="justify-content:space-between;cursor:pointer;margin-top:10px"><span>Boxes behind the game's panels<br><span class="t" style="font-size:11.5px">Keeps numbers readable on busy pictures.</span></span><span class="sw"><input type="checkbox" id="skinframes" checked><span></span></span></label>
            <label class="row" style="justify-content:space-between;cursor:pointer;margin-top:8px"><span>Glow effect</span><span class="sw"><input type="checkbox" id="skinglow"><span></span></span></label>
            <div class="row" style="margin-top:10px;justify-content:flex-end;gap:10px"><span class="t" id="skinmsg"></span><button class="btn" id="skinmake">Add to game</button></div>
          </div>
        </div>
        <div class="card"><h3>Skins in your game</h3><div id="skinlist"><div class="t">Loading...</div></div>
          <div class="t" style="font-size:11.5px;margin-top:8px">Pick a skin in Screen Stocks' skin settings. If a new one doesn't show up, restart the game. "Show in game" hides or shows a skin in the game's list.</div></div>
      </section>
      <section class="tab" id="t-profit">
        <div class="card"><div class="t">Profit today</div><div class="hero m" id="pHero">-</div><div class="t m" id="pSub"></div></div>
        <div class="card" style="position:relative"><h3>Last 14 days</h3><div class="bars" id="bars"></div><div class="blabels" id="blabels"></div><div class="tip" id="btip"></div></div>
        <div class="card"><table><thead><tr><th>Day</th><th>Start</th><th>End</th><th>Profit</th></tr></thead><tbody id="ptab"></tbody></table>
          <div class="t" style="font-size:11.5px;margin-top:8px">Profit = change in net worth while the panel was running that day. Going Public resets your money, so that day shows a loss.</div></div>
      </section>
      <section class="tab" id="t-calc">
        <div class="cdisp"><input id="cin" class="m" placeholder="e.g. 2.5qa * 25%  or  (650-330)*1m" autocomplete="off"><div class="cres m" id="cres"></div></div>
        <div class="chips" id="cchips"></div>
        <div class="keys" id="keys"></div>
        <div class="card" style="margin-top:10px"><h3>Trade helper</h3>
          <div class="helper"><span class="t">Buy at</span><input id="hB" class="m" type="text" placeholder="price"><span class="t">Sell at</span><input id="hS" class="m" type="text" placeholder="price"><span class="t">Money in (k, m, b, t, qa... ok)</span><input id="hM" class="m" type="text" placeholder="e.g. 500m"></div>
          <div class="out"><div><div class="l">Shares</div><div class="v m" id="hSh">-</div></div><div><div class="l">Profit</div><div class="v m" id="hP">-</div></div><div><div class="l">Return</div><div class="v m" id="hR">-</div></div></div>
        </div>
      </section>
      <section class="tab" id="t-log">
        <div class="card" id="setcard"><h3>Settings</h3>
          <label class="row" style="justify-content:space-between;cursor:pointer"><span>Share prices with other StockPilot players<br><span class="t" style="font-size:11.5px">Screen Stocks has one market for everyone. StockPilot sends the prices it sees and fills the times your game was closed with prices other players saw. Only stock prices are shared, never your cash, shares or account.</span></span><span class="sw"><input type="checkbox" id="share"><span></span></span></label>
          <div class="t" id="sharemsg" style="font-size:11.5px;margin-top:6px"></div>
          <div class="row" id="shareurlrow" style="display:none;margin-top:8px;gap:6px"><input type="text" id="shareurl" placeholder="https://stockpilot.yourname.workers.dev" style="flex:1"><button class="btn" id="shareurlsave">Save</button></div>
          <div id="winset" style="margin-top:12px"><label class="row" style="justify-content:space-between;cursor:pointer"><span>Start with Windows<br><span class="t" style="font-size:11.5px">Runs quietly in the background so prices are always recorded. Clicking StockPilot opens the window.</span></span><span class="sw"><input type="checkbox" id="autostart"><span></span></span></label>
          <label class="row" style="justify-content:space-between;cursor:pointer;margin-top:10px"><span>Open Screen Stocks when the PC starts<br><span class="t" style="font-size:11.5px">Prices are only tracked while the game is open, so this opens it for you after a restart.</span></span><span class="sw"><input type="checkbox" id="autogame"><span></span></span></label>
          <label class="row" style="justify-content:space-between;cursor:pointer;margin-top:10px"><span>Keep the PC awake while tracking<br><span class="t" style="font-size:11.5px">Stops sleep so tracking and trading don't pause. The screen can still turn off.</span></span><span class="sw"><input type="checkbox" id="awake"><span></span></span></label></div></div>
        <div class="card"><h3>Trades today</h3><div class="log" id="trades"></div></div>
        <div class="card"><h3>Activity</h3><div class="log" id="log"></div></div>
      </section>
    </div>
  </aside>
</div>
<div class="over" id="over"></div>
<script>
const TOKEN='__TOKEN__';
const $=s=>document.querySelector(s);
const UP='#86e08f',DOWN='#f07178',BLUE='#4f8ff7',ORANGE='#f0a35e',AQUA='#2fc79a',GRID='#202228',AXIS='#7f7e79',GRAYL='#9a9ca3',MONO='11px "Cascadia Mono",Consolas,"SF Mono",Menlo,monospace';
let S=null,rules=[],dry=true,version=-1,dirty=false,saveTimer=null,tab='rules',gStock=null,gRange='15m',G=null,lastG=0,daily=[],lastLogId=0,hover=null,geo=null,stopped=false;
function fmtShort(n){if(n==null||isNaN(n))return'-';const a=Math.abs(n);for(const[v,s]of[[1e27,'Oc'],[1e24,'Sp'],[1e21,'Sx'],[1e18,'Qi'],[1e15,'Qa'],[1e12,'T'],[1e9,'B'],[1e6,'M'],[1e3,'K']])if(a>=v){const x=n/v;return(Math.abs(x)>=100?x.toFixed(0):Math.abs(x)>=10?x.toFixed(1):x.toFixed(2))+s}return a<1000?(+n.toFixed(2)).toString():n.toFixed(0)}
function fmtP(n){if(n==null||isNaN(n))return'-';const a=Math.abs(n);return a>=1e5?fmtShort(n):a>=1000?n.toLocaleString('en-US',{maximumFractionDigits:1}):n.toFixed(3)}
function fmtFull(n){if(n==null||isNaN(n))return'-';return n.toLocaleString('en-US',{maximumFractionDigits:Math.abs(n)<100?4:0})}
function signed(n,f){f=f||fmtShort;if(n==null||isNaN(n))return'-';return(n>0?'+':n<0?'\u2212':'')+f(Math.abs(n))}
const pctS=x=>x==null||isNaN(x)?'':signed(x,v=>v.toFixed(2))+'%';
const norm=s=>String(s||'').trim().replace(/^\$/,'').toUpperCase();
const esc=s=>String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const cap=s=>s.charAt(0).toUpperCase()+s.slice(1);
async function api(p,b){const r=await fetch(p,b===undefined?{cache:'no-store'}:{method:'POST',headers:{'Content-Type':'application/json','X-Token':TOKEN},body:JSON.stringify(b)});if(!r.ok)throw new Error(r.status);return r.json()}
function findStock(name){if(!S)return null;const k=norm(name);return S.stocks.find(s=>norm(s.name)===k||norm(s.id)===k)||null}
function stockById(id){if(!S)return null;if(id==='__NW')return{id:'__NW',name:'Net worth',price:S.netWorth,chg:S.nwChg};return S.stocks.find(s=>s.id===id)||null}

/* header + polling */
function renderHeader(){
  $('#dot').className='dot '+(S.connected?'on':'warn');$('#status').textContent=S.status;
  renderMode();$('#pause').textContent=S.paused?'Resume':'Pause';$('#pause').classList.toggle('on',S.paused);
  $('#pin').style.display=S.pinAvailable?'':'none';$('#pin').classList.toggle('on',S.pinned);$('#pin').textContent=S.pinned?'On top \u2713':'Pin on top';
  $('#cash').textContent=fmtShort(S.cash);$('#cash').title=fmtFull(S.cash);
  $('#nw').textContent=fmtShort(S.netWorth);$('#nw').title=fmtFull(S.netWorth);$('#nwl').textContent=S.netWorthEst?'Net worth (est.)':'Net worth';
  const tp=S.todayProfit;$('#today').textContent=tp==null?'-':signed(tp);$('#today').className='v m '+(tp>0?'up':tp<0?'down':'');
  $('#cdb').textContent=S.buyIn>0?Math.ceil(S.buyIn)+'s':'ready';$('#cds').textContent=S.shortIn>0?Math.ceil(S.shortIn)+'s':'ready';
  const b=$('#banner');if(S.setup!=='ok'&&S.setupMsg){b.className='banner';b.textContent='Setup: '+S.setupMsg;b.style.display='block'}else if(S.rulesError){b.className='banner err';b.textContent=S.rulesError;b.style.display='block'}else b.style.display='none';
}
function renderSettings(){$('#winset').style.display=S.autostartAvailable?'':'none';for(const[id,v]of[['autostart',S.autostart],['autogame',S.autoGame],['awake',S.awake],['share',S.shareOn]]){const a=$('#'+id);if(document.activeElement!==a)a.checked=!!v}
$('#sharemsg').textContent=S.shareMsg||'';$('#shareurlrow').style.display=S.shareNeedsUrl?'flex':'none';const u=$('#shareurl');if(document.activeElement!==u&&!u.dataset.typed)u.value=S.shareUrl||''}
$('#share').addEventListener('change',e=>api('/api/settings',{share:e.target.checked}).catch(()=>{}));
$('#shareurl').addEventListener('input',e=>{e.target.dataset.typed='1'});
$('#shareurlsave').onclick=()=>{const u=$('#shareurl');api('/api/settings',{shareUrl:u.value.trim()}).catch(()=>{});delete u.dataset.typed};
$('#autogame').addEventListener('change',e=>api('/api/settings',{autoGame:e.target.checked}).catch(()=>{}));
$('#awake').addEventListener('change',e=>api('/api/settings',{awake:e.target.checked}).catch(()=>{}));
$('#autostart').addEventListener('change',e=>api('/api/autostart',{on:e.target.checked}).catch(()=>{}));
function renderMode(){for(const b of document.querySelectorAll('#mode button')){const live=b.dataset.m==='live';b.className=(live!==dry?'sel '+(live?'live':'prac'):'')}}
async function poll(){if(stopped)return;try{S=await api('/api/state');$('#over').style.display='none';if(!gStock||gStock==='__NW')gStock=(S.stocks[0]&&S.stocks[0].id)||null;sync();renderHeader();renderTicker();renderLog();renderSettings();fillQa();if(tab==='profit')renderProfitHero();if(tab==='calc')renderCalcChips();updateHead();draw()}
  catch(e){const o=$('#over');o.innerHTML='The bot isn\u2019t running.<br><br>Open <b>StockPilot</b> again to start it.';o.style.display='flex'}finally{setTimeout(poll,1000)}}

/* ticker */
function renderTicker(){const items=S.stocks;
  $('#ticker').innerHTML=items.map(s=>{const c=s.chg,inv=(s.owned>0||s.shorted>0||s.id==='__NW');return`<button class="tk${s.id===gStock?' sel':''}" data-s="${esc(s.id)}"><div class="n">${esc(s.name||s.id)}${s.owned>0?' <span class="t" style="font-weight:400">\u00b7 own</span>':''}</div><div><span class="p m">${s.id==='__NW'?fmtShort(s.price):fmtP(s.price)}</span><span class="c m ${inv?(c>0?'up':c<0?'down':''):''}">${inv&&c!=null?pctS(c):''}</span></div></button>`}).join('')}
$('#ticker').onclick=e=>{const b=e.target.closest('.tk');if(!b)return;gStock=b.dataset.s;G=null;draw();renderTicker();loadGraph()};

/* rules */
function rulesFocused(){const a=document.activeElement;return a&&a.closest&&a.closest('#rules')&&a.tagName!=='BUTTON'}
let namesKey='';
function sync(){const nk=S.stocks.map(s=>s.id+':'+(s.name||'')).join('|');if(!dirty&&S.rulesVersion!==version&&!rulesFocused()){rules=S.rules.map(r=>Object.assign({},r));dry=S.dry;version=S.rulesVersion;namesKey=nk;renderRules()}else if(nk!==namesKey&&!dirty&&!rulesFocused()){namesKey=nk;renderRules()}else updateRuleStatus()}
function stockNames(){return S?S.stocks.map(s=>s.name||s.id):[]}
function stockOptions(cur){const list=S?S.stocks:[],k=norm(cur),hit=s=>norm(s.name)===k||norm(s.id)===k;let h='';if(!cur)h+='<option value="">Pick stock</option>';else if(!list.some(hit))h+=`<option value="${esc(cur)}" selected>${esc(cur)} (not in game)</option>`;for(const s of list){const n=s.name||s.id;h+=`<option value="${esc(n)}" ${hit(s)?'selected':''}>${esc(n)}</option>`}return h}
function renderRules(){const box=$('#rules');
  if(!rules.length){box.innerHTML='<div class="empty">No auto actions yet. Use Buy low, sell high above, or + Add auto action.</div>';return}
  box.innerHTML=rules.map((r,i)=>`<div class="rule${r.enabled?'':' off'}" data-i="${i}">
   <div class="r1"><label class="sw" title="On / off"><input type="checkbox" data-k="enabled" ${r.enabled?'checked':''}><span></span></label>
    <select data-k="action" class="act act-${r.action}">${['buy','sell','short','cover','close'].map(a=>`<option value="${a}" ${a===r.action?'selected':''}>${cap(a)}</option>`).join('')}</select>
    <input data-k="percent" class="pct m" type="number" min="1" max="100" value="${r.percent}"><span class="t">% of</span>
    <select data-k="stock" class="stk">${stockOptions(r.stock)}</select><button class="x" data-del title="Delete auto action">&times;</button></div>
   <div class="r2"><span class="t">when price is</span><select data-k="when">${['below','above'].map(w=>`<option value="${w}" ${w===r.when?'selected':''}>${w}</option>`).join('')}</select>
    <input data-k="price" class="price m" type="number" step="any" value="${r.price}"><label class="rep"><input type="checkbox" data-k="repeat" ${r.repeat?'checked':''}>repeat</label></div>
   <div class="r3"><span class="now m"></span><span class="st"></span></div></div>`).join('');
  updateRuleStatus()}
function updateRuleStatus(){document.querySelectorAll('#rules .rule').forEach(el=>{const i=+el.dataset.i,r=rules[i];if(!r)return;const st=findStock(r.stock),pill=el.querySelector('.st'),now=el.querySelector('.now');
  const rs=(!dirty&&S&&S.ruleStatus[i])||{};let txt,cls='';
  now.textContent=st?('now '+fmtP(st.price)+(st.owned>0?' \u00b7 own '+fmtShort(st.owned):'')+(st.shorted>0?' \u00b7 short '+fmtShort(st.shorted):'')):(S&&S.stocks.length?'stock not found':'');
  if(rs.problem){txt=rs.problem;cls='bad'}else if(!r.enabled){txt='Off'}else if(dirty){txt='Saving...'}else if(!st){txt='Waiting for game'}
  else{const met=r.when==='below'?st.price<r.price:st.price>r.price;
    if(rs.fired&&!r.repeat){txt='Fired \u00b7 re-arms when price crosses back';cls='done'}
    else if(met){if((r.action==='sell'&&st.owned<=0)||(r.action==='cover'&&st.shorted<=0))txt='Line hit \u00b7 you own none';else{txt=S.paused?'Line hit \u00b7 paused':'Line hit \u00b7 firing';cls='go'}}
    else{const d=Math.abs(st.price-r.price)/(st.price||1)*100;txt=(d<0.1?'<0.1':d.toFixed(d<10?1:0))+'% away'}}
  pill.textContent=txt;pill.className='st '+cls})}
function scheduleSave(){dirty=true;$('#saved').textContent='Saving...';updateRuleStatus();clearTimeout(saveTimer);saveTimer=setTimeout(save,450);draw()}
async function save(){clearTimeout(saveTimer);try{await api('/api/rules',{dry,rules});dirty=false;version=-1;$('#saved').textContent='Saved \u2713'}catch(e){$('#saved').textContent='Could not save - is the bot running?'}}
$('#rules').addEventListener('input',e=>{const el=e.target.closest('.rule');const k=e.target.dataset.k;if(!el||!k)return;const r=rules[+el.dataset.i];
  if(e.target.type==='checkbox')r[k]=e.target.checked;else if(k==='percent'||k==='price')r[k]=parseFloat(e.target.value)||0;else r[k]=e.target.value;
  if(k==='enabled')el.classList.toggle('off',!r.enabled);if(k==='action')e.target.className='act act-'+r.action;scheduleSave()});
$('#rules').addEventListener('click',e=>{if(!e.target.matches('[data-del]'))return;rules.splice(+e.target.closest('.rule').dataset.i,1);renderRules();scheduleSave()});
$('#addRule').onclick=()=>{const st=stockById(gStock);const s=st&&st.id!=='__NW'?st:(S&&S.stocks[0]);rules.push({stock:s?(s.name||s.id):'',action:'buy',when:'below',price:s?+(+s.price).toFixed(3):0,percent:100,repeat:false,enabled:true});renderRules();scheduleSave();const l=$('#rules').lastElementChild;if(l)l.scrollIntoView({block:'nearest'})};
function fillQa(){const sel=$('#qaStock'),names=stockNames(),cur=sel.value;const key=names.join('|');if(sel.dataset.k===key)return;sel.dataset.k=key;sel.innerHTML=names.map(n=>`<option ${n===cur?'selected':''}>${esc(n)}</option>`).join('')||'<option value="">no stocks yet</option>'}
$('#qaAdd').onclick=()=>{const s=$('#qaStock').value,b=parseFloat($('#qaBuy').value),x=parseFloat($('#qaSell').value),p=Math.min(100,Math.max(1,parseInt($('#qaPct').value)||100));
  if(!s){$('#saved').textContent='Open the game first so stocks show up';return}if(!b&&!x){$('#qaBuy').focus();return}
  if(b>0)rules.push({stock:s,action:'buy',when:'below',price:b,percent:p,repeat:false,enabled:true});if(x>0)rules.push({stock:s,action:'sell',when:'above',price:x,percent:100,repeat:false,enabled:true});
  $('#qaBuy').value='';$('#qaSell').value='';renderRules();scheduleSave()};
$('#mode').onclick=e=>{const m=e.target.dataset.m;if(!m)return;const wantLive=m==='live';if(wantLive===!dry)return;
  if(wantLive&&!confirm('Switch to LIVE? Your auto actions will place real trades in the game.'))return;dry=!wantLive;renderMode();save()};
$('#pause').onclick=()=>api('/api/pause',{paused:!(S&&S.paused)}).catch(()=>{});
$('#pin').onclick=()=>api('/api/pin',{on:!(S&&S.pinned)}).catch(()=>{});
$('#edit').onclick=()=>api('/api/edit',{}).catch(()=>{});
$('#stop').onclick=async()=>{if(!confirm('Stop the bot? Trading stops until you open StockPilot again.'))return;stopped=true;try{await api('/api/quit',{})}catch(e){}
  const o=$('#over');o.innerHTML='Bot stopped.<br><br>Open <b>StockPilot</b> again to start it.';o.style.display='flex';setTimeout(()=>window.close(),600)};
function renderLog(){const box=$('#log');const items=S.log.filter(l=>l.id>lastLogId);if(items.length){lastLogId=items[items.length-1].id;
  for(const l of items){const d=document.createElement('div');d.innerHTML=`<span class="tm m">${l.t}</span><span class="${l.kind==='err'?'err2':l.kind}">${esc(l.msg)}</span>`;box.prepend(d)}while(box.children.length>120)box.lastChild.remove()}
  $('#trades').innerHTML=S.trades.length?S.trades.slice().reverse().map(t=>`<div><span class="tm m">${new Date(t.t).toLocaleTimeString()}</span><span class="${t.action==='buy'||t.action==='cover'?'ok':'err2'}">${t.action.toUpperCase()}</span><span>${fmtShort(t.qty)} ${esc(t.stock)} @ <span class="m">${fmtP(t.price)}</span></span><span class="t" style="margin-left:auto">${t.src}</span></div>`).join(''):'<div class="t">No trades yet today.</div>'}

/* tabs */
document.querySelector('nav').onclick=e=>{const t=e.target.dataset.t;if(!t)return;tab=t;for(const b of document.querySelectorAll('nav button'))b.classList.toggle('sel',b.dataset.t===t);
  for(const s of document.querySelectorAll('.tab'))s.classList.toggle('sel',s.id==='t-'+t);if(t==='profit'){renderProfitHero();loadDaily()}if(t==='calc')renderCalcChips();if(t==='skin')loadSkins()};
// ---- skins  (pictures, GIFs and MP4/WebM videos; videos & GIFs loop up to 15s)
let skinCanvas=null,skinBg='#1A1B1F',skinFrames=[],skinFps=10;
const STATICCAP=2560,ANIMCAP=960,ANIMFPS=10,ANIMMAXSEC=15,ANIMMAXFRAMES=150;
const hex2=(r,g,b)=>'#'+[r,g,b].map(v=>Math.max(0,Math.min(255,Math.round(v))).toString(16).padStart(2,'0')).join('');
function rgb2hsv(r,g,b){r/=255;g/=255;b/=255;const mx=Math.max(r,g,b),mn=Math.min(r,g,b),d=mx-mn;let h=0;if(d){if(mx===r)h=((g-b)/d)%6;else if(mx===g)h=(b-r)/d+2;else h=(r-g)/d+4;h*=60;if(h<0)h+=360}return[h,mx?d/mx:0,mx]}
function hsv2rgb(h,s,v){const c=v*s,x=c*(1-Math.abs((h/60)%2-1)),m=v-c;const[r,g,b]=h<60?[c,x,0]:h<120?[x,c,0]:h<180?[0,c,x]:h<240?[0,x,c]:h<300?[x,0,c]:[c,0,x];return[(r+m)*255,(g+m)*255,(b+m)*255]}
function pickColors(src){const c=document.createElement('canvas');c.width=c.height=48;const x=c.getContext('2d');x.drawImage(src,0,0,48,48);const d=x.getImageData(0,0,48,48).data;
  const bins=Array.from({length:12},()=>({w:0,h:0}));let ar=0,ag=0,ab=0,n=0;
  for(let i=0;i<d.length;i+=4){const r=d[i],g=d[i+1],b=d[i+2];ar+=r;ag+=g;ab+=b;n++;const[h,s,v]=rgb2hsv(r,g,b);const w=s*s*v,k=Math.floor(h/30)%12;bins[k].w+=w;bins[k].h+=h*w}
  ar/=n;ag/=n;ab/=n;const best=bins.reduce((a,b)=>b.w>a.w?b:a);const[mh,ms]=rgb2hsv(ar,ag,ab);const hue=best.w>1?best.h/best.w:mh;
  return{glow:hex2(...hsv2rgb(hue,best.w>1?.75:.15,.95)),panels:hex2(...hsv2rgb(mh,Math.min(ms,.35),.16)),buttons:hex2(...hsv2rgb(hue,Math.min(.45,best.w>1?.45:ms),.30)),bg:hex2(...hsv2rgb(mh,Math.min(ms,.3),.10))}}
// fit the whole picture onto a screen-shaped canvas (stops the game zooming/cropping)
function sTgt(cap){const dpr=window.devicePixelRatio||1;let w=Math.round((screen.width||1600)*dpr),h=Math.round((screen.height||900)*dpr);if(!(w>1)||!(h>1)){w=1920;h=1080}const mx=Math.max(w,h);if(mx>cap){const s=cap/mx;w=Math.round(w*s);h=Math.round(h*s)}return[Math.max(2,w),Math.max(2,h)]}
function fitCanvas(src,sw,sh,W,H,bg){const c=document.createElement('canvas');c.width=W;c.height=H;const x=c.getContext('2d');x.fillStyle=bg;x.fillRect(0,0,W,H);const s=Math.min(W/sw,H/sh),w=Math.round(sw*s),h=Math.round(sh*s);x.imageSmoothingEnabled=true;x.imageSmoothingQuality='high';x.drawImage(src,0,0,sw,sh,Math.round((W-w)/2),Math.round((H-h)/2),w,h);return c}
function nameFrom(fn){return(fn.replace(/\.[^.]+$/,'').replace(/[^A-Za-z0-9 _\-.!]/g,' ').replace(/\s+/g,' ').trim().slice(0,40))||'My skin'}
function applyColors(k,fn){$('#skinpanels').value=k.panels;$('#skinbuttons').value=k.buttons;$('#skinglowc').value=k.glow;skinBg=k.bg;if(fn)$('#skinname').value=nameFrom(fn)}
function resetSkin(){skinCanvas=null;skinFrames=[];$('#skinanim').style.display='none'}
function seekTo(v,t){return new Promise(res=>{let done=false;const on=()=>{if(done)return;done=true;v.removeEventListener('seeked',on);res()};v.addEventListener('seeked',on);try{v.currentTime=t}catch(e){on()}setTimeout(on,1500)})}
async function framesFromVideo(f){const v=document.createElement('video');v.muted=true;v.playsInline=true;v.preload='auto';v.src=URL.createObjectURL(f);
  await new Promise((res,rej)=>{v.onloadedmetadata=()=>res();v.onerror=()=>rej(new Error('Could not read that video.'))});
  let dur=v.duration;if(!isFinite(dur)||dur<=0)throw new Error('Could not read that video.');dur=Math.min(ANIMMAXSEC,dur);
  await seekTo(v,0);const vw=v.videoWidth,vh=v.videoHeight;if(!vw||!vh){URL.revokeObjectURL(v.src);throw new Error('Could not read that video.')}
  const first=document.createElement('canvas');first.width=vw;first.height=vh;first.getContext('2d').drawImage(v,0,0,vw,vh);
  const k=pickColors(first);applyColors(k,f.name);const n=Math.max(1,Math.min(ANIMMAXFRAMES,Math.round(dur*ANIMFPS)));const[W,H]=sTgt(ANIMCAP);const frames=[];
  for(let i=0;i<n;i++){await seekTo(v,dur*i/n);frames.push(fitCanvas(v,vw,vh,W,H,k.bg).toDataURL('image/jpeg',.82).split(',')[1])}
  URL.revokeObjectURL(v.src);return{frames,fps:Math.max(1,Math.round(n/dur))}}
// GIF frame decoder (works in every browser; Chrome/Edge/Brave use the faster built-in ImageDecoder when present)
function _lzw(minCode,data,pixelCount){const clear=1<<minCode,eoi=clear+1;let size=minCode+1,dict=[];const init=()=>{dict=[];for(let i=0;i<clear;i++)dict[i]=[i];dict[clear]=null;dict[eoi]=null;size=minCode+1};init();const out=new Uint8Array(pixelCount);let oi=0,bit=0,prev=null;const read=()=>{let c=0;for(let i=0;i<size;i++){c|=((data[bit>>3]>>(bit&7))&1)<<i;bit++}return c};while(oi<pixelCount){const code=read();if(code===clear){init();prev=null;continue}if(code===eoi)break;let e;if(code<dict.length&&dict[code])e=dict[code];else if(prev)e=prev.concat(prev[0]);else break;for(let i=0;i<e.length&&oi<pixelCount;i++)out[oi++]=e[i];if(prev){dict.push(prev.concat(e[0]));if(dict.length===(1<<size)&&size<12)size++}prev=e}return out}
function _deint(il,ih){const r=[];if(!il){for(let i=0;i<ih;i++)r.push(i);return r}for(const p of[[0,8],[4,8],[2,4],[1,2]])for(let i=p[0];i<ih;i+=p[1])r.push(i);return r}
function decodeGif(buf){const b=new Uint8Array(buf);let p=0;if(String.fromCharCode(b[0],b[1],b[2])!=='GIF')throw new Error('Not a GIF.');p=6;const rw=()=>{const v=b[p]|(b[p+1]<<8);p+=2;return v},rd=()=>b[p++];const W=rw(),H=rw(),pk=rd();rd();rd();let gct=null;if(pk&0x80){const n=2<<(pk&7);gct=b.subarray(p,p+n*3);p+=n*3}const frames=[];let delay=100,tIndex=-1,disposal=0;const cv=new Uint8ClampedArray(W*H*4);let prev=null;while(p<b.length){const bl=rd();if(bl===0x3B||bl===undefined)break;if(bl===0x21){const lb=rd();if(lb===0xF9){rd();const f=rd();delay=rw()*10||100;tIndex=(f&1)?rd():(rd(),-1);disposal=(f>>2)&7;rd()}else{let s;while((s=rd()))p+=s}continue}if(bl===0x2C){const ix=rw(),iy=rw(),iw=rw(),ih=rw(),ip=rd();let ct=gct;if(ip&0x80){const n=2<<(ip&7);ct=b.subarray(p,p+n*3);p+=n*3}if(!ct)break;const mc=rd(),ch=[];let s;while((s=rd())){ch.push(b.subarray(p,p+s));p+=s}let ln=0;ch.forEach(c=>ln+=c.length);const data=new Uint8Array(ln);let o=0;ch.forEach(c=>{data.set(c,o);o+=c.length});const idx=_lzw(mc,data,iw*ih),rows=_deint(ip&0x40,ih);if(disposal===3)prev=cv.slice();for(let dr=0;dr<ih;dr++){const oR=rows[dr];for(let c=0;c<iw;c++){const ci=idx[dr*iw+c];if(ci===tIndex)continue;const px=((iy+oR)*W+(ix+c))*4;cv[px]=ct[ci*3];cv[px+1]=ct[ci*3+1];cv[px+2]=ct[ci*3+2];cv[px+3]=255}}frames.push({data:cv.slice(),delay});if(disposal===2){for(let r=0;r<ih;r++)for(let c=0;c<iw;c++){const px=((iy+r)*W+(ix+c))*4;cv[px]=cv[px+1]=cv[px+2]=cv[px+3]=0}}else if(disposal===3&&prev)cv.set(prev);tIndex=-1;continue}}if(!frames.length)throw new Error('Could not read that GIF.');return{width:W,height:H,frames}}
async function gifRawFrames(f){const ab=await f.arrayBuffer();
  if(typeof ImageDecoder!=='undefined'){try{const dec=new ImageDecoder({data:ab,type:'image/gif'});await dec.completed;const tr=dec.tracks&&dec.tracks.selectedTrack,total=(tr&&tr.frameCount)||1,raw=[];for(let i=0;i<total;i++){let r;try{r=await dec.decode({frameIndex:i})}catch(e){break}const im=r.image;raw.push({img:im,w:im.displayWidth||im.codedWidth,h:im.displayHeight||im.codedHeight,dms:(im.duration||100000)/1000,close:()=>{try{im.close()}catch(e){}}})}if(raw.length>1)return raw;raw.forEach(r=>r.close())}catch(e){}}
  const g=decodeGif(ab);return g.frames.map(fr=>{const c=document.createElement('canvas');c.width=g.width;c.height=g.height;c.getContext('2d').putImageData(new ImageData(fr.data,g.width,g.height),0,0);return{img:c,w:g.width,h:g.height,dms:fr.delay,close:()=>{}}})}
async function framesFromGif(f){let raw;try{raw=await gifRawFrames(f)}catch(e){return null}if(!raw||raw.length<2){if(raw)raw.forEach(r=>r.close());return null}
  const fc=document.createElement('canvas');fc.width=raw[0].w;fc.height=raw[0].h;fc.getContext('2d').drawImage(raw[0].img,0,0);const k=pickColors(fc);applyColors(k,f.name);
  const[W,H]=sTgt(ANIMCAP);const tot=Math.min(ANIMMAXSEC*1000,raw.reduce((a,r)=>a+r.dms,0)),step=1000/ANIMFPS,frames=[];let idx=0,cum=raw[0].dms;
  for(let t=0;t<tot&&frames.length<ANIMMAXFRAMES;t+=step){while(idx<raw.length-1&&t>=cum){idx++;cum+=raw[idx].dms}frames.push(fitCanvas(raw[idx].img,raw[idx].w,raw[idx].h,W,H,k.bg).toDataURL('image/jpeg',.82).split(',')[1])}
  raw.forEach(r=>r.close());return{frames,fps:ANIMFPS}}
function staticImage(f){return new Promise((res,rej)=>{const url=URL.createObjectURL(f),im=new Image();
  im.onload=()=>{const nw=im.naturalWidth,nh=im.naturalHeight;if(!nw||!nh){URL.revokeObjectURL(url);return rej(new Error("Couldn't read that picture."))}
    const native=document.createElement('canvas');native.width=nw;native.height=nh;native.getContext('2d').drawImage(im,0,0);const k=pickColors(native);applyColors(k,f.name);
    const[W,H]=sTgt(STATICCAP);skinCanvas=fitCanvas(im,nw,nh,W,H,k.bg);$('#skinprev').src=skinCanvas.toDataURL('image/jpeg',.82);$('#skinanim').style.display='none';$('#skinform').style.display='';URL.revokeObjectURL(url);res()};
  im.onerror=()=>{URL.revokeObjectURL(url);rej(new Error("Couldn't read that picture."))};im.src=url})}
function setAnim(r){skinFrames=r.frames;skinFps=r.fps||ANIMFPS;skinCanvas=null;$('#skinprev').src='data:image/jpeg;base64,'+r.frames[0];
  const a=$('#skinanim');a.style.display='';a.textContent='Animated \u00b7 '+r.frames.length+' frames \u00b7 '+skinFps+' fps \u00b7 loops while the game is open';$('#skinform').style.display=''}
async function skinFile(f){const m=$('#skinmsg');m.textContent='';resetSkin();if(!f)return;
  const isVid=/^video\//.test(f.type)||/\.(mp4|webm|mov|m4v)$/i.test(f.name),isGif=f.type==='image/gif'||/\.gif$/i.test(f.name);
  try{if(isVid){m.textContent='Reading video\u2026';setAnim(await framesFromVideo(f));m.textContent=''}
    else if(isGif){m.textContent='Reading GIF\u2026';const r=await framesFromGif(f);if(r)setAnim(r);else await staticImage(f);m.textContent=''}
    else await staticImage(f)}
  catch(e){resetSkin();m.textContent=e.message||'Could not read that file.';$('#skinform').style.display='none'}}
$('#skinpick').onclick=()=>$('#skinfile').click();
$('#skinfile').onchange=e=>{skinFile(e.target.files[0]);e.target.value=''};
const dz=$('#drop');dz.addEventListener('dragover',e=>{e.preventDefault();dz.classList.add('over')});dz.addEventListener('dragleave',()=>dz.classList.remove('over'));
dz.addEventListener('drop',e=>{e.preventDefault();dz.classList.remove('over');if(e.dataTransfer.files[0])skinFile(e.dataTransfer.files[0])});
function thumbFrom(dataURL){return new Promise(res=>{const img=new Image();img.onload=()=>{const sc=320/img.width,t=document.createElement('canvas');t.width=320;t.height=Math.max(1,Math.round(img.height*sc));t.getContext('2d').drawImage(img,0,0,t.width,t.height);res(t.toDataURL('image/jpeg',.72))};img.onerror=()=>res('');img.src=dataURL})}
$('#skinmake').onclick=async()=>{const m=$('#skinmsg'),b=$('#skinmake');const anim=skinFrames.length>1;if(!skinCanvas&&!anim)return;const name=$('#skinname').value.trim();
  if(!/^[A-Za-z0-9 _\-.!]{1,40}$/.test(name)){m.textContent='Name: letters, numbers, spaces, - _ . ! only.';return}
  const list=await fetch('/api/skins',{cache:'no-store'}).then(r=>r.json()).catch(()=>[]);const slug='sp-'+(name.toLowerCase().replace(/[^a-z0-9]+/g,'-').replace(/^-+|-+$/g,'')||'skin')+'.json';
  if(list.some(s=>s.file===slug)&&!confirm('A skin called "'+name+'" already exists. Replace it?'))return;
  b.disabled=true;m.textContent='Adding\u2026';
  try{const meta={name,panels:$('#skinpanels').value,buttons:$('#skinbuttons').value,bg:skinBg,frames:$('#skinframes').checked,glow:$('#skinglow').checked,glowColor:$('#skinglowc').value};
    if(anim){meta.fps=skinFps;meta.count=skinFrames.length;meta.thumb=await thumbFrom('data:image/jpeg;base64,'+skinFrames[0]);
      const start=await fetch('/api/skinanim',{method:'POST',headers:{'Content-Type':'text/plain','X-Token':TOKEN},body:JSON.stringify(meta)}).then(r=>r.json());
      if(!start.ok)throw new Error(start.error||'Could not start.');const base=start.base;
      for(let i=0;i<skinFrames.length;i++){m.textContent='Adding frame '+(i+1)+'/'+skinFrames.length+'\u2026';
        const fr=await fetch('/api/skinframe',{method:'POST',headers:{'Content-Type':'text/plain','X-Token':TOKEN},body:base+' '+i+'\n'+skinFrames[i]}).then(r=>r.json());
        if(!fr.ok)throw new Error(fr.error||'Upload failed at frame '+(i+1)+'.')}
      const done=await fetch('/api/skinanimdone',{method:'POST',headers:{'Content-Type':'application/json','X-Token':TOKEN},body:JSON.stringify({base,count:skinFrames.length})}).then(r=>r.json());
      if(!done.ok)throw new Error(done.error||'Could not finish.');
      m.textContent='Added! Pick "'+name+'" in the game\u2019s skin settings \u2014 it loops while the game is open.';loadSkins()}
    else{const c=skinCanvas;meta.thumb=await thumbFrom(c.toDataURL('image/jpeg',.82));const png=c.toDataURL('image/png').split(',')[1];
      const r=await fetch('/api/skin',{method:'POST',headers:{'Content-Type':'text/plain','X-Token':TOKEN},body:JSON.stringify(meta)+'\n'+png}).then(r=>r.json());
      if(!r.ok)throw new Error(r.error||'Something went wrong.');m.textContent='Added! Pick "'+name+'" in the game\u2019s skin settings.';loadSkins()}}
  catch(e){m.textContent=e.message||'Something went wrong.'}finally{b.disabled=false}};
async function loadSkins(){const el=$('#skinlist');let list;try{list=await fetch('/api/skins',{cache:'no-store'}).then(r=>r.json())}catch(e){el.innerHTML='<div class="t">Couldn\u2019t read the skins folder.</div>';return}
  if(!list.length){el.innerHTML='<div class="t">No skins yet.</div>';return}
  el.innerHTML=list.map(s=>`<div class="skrow">${s.thumb?`<img src="${s.thumb}" alt="">`:'<div class="ph"></div>'}<div class="nm">${esc(s.name)}${s.anim?' <span class="t">(looping)</span>':''}${s.ours?'':' <span class="t">(game example)</span>'}</div>
    <label class="row t" style="gap:6px;font-size:11.5px;cursor:pointer">Show in game <span class="sw"><input type="checkbox" data-f="${esc(s.file)}" ${s.enabled?'checked':''}><span></span></span></label>
    ${s.ours?`<button class="link" data-del="${esc(s.file)}" data-n="${esc(s.name)}">Delete</button>`:''}</div>`).join('')}
$('#skinlist').addEventListener('change',e=>{const f=e.target.dataset.f;if(f)api('/api/skinset',{file:f,enabled:e.target.checked}).catch(()=>{})});
$('#skinlist').addEventListener('click',e=>{const f=e.target.dataset.del;if(!f)return;if(!confirm('Delete the skin "'+e.target.dataset.n+'"?'))return;api('/api/skindel',{file:f}).then(loadSkins).catch(()=>{})});

/* chart */
$('#range').onclick=e=>{const r=e.target.dataset.r;if(!r)return;gRange=r;for(const b of document.querySelectorAll('#range button'))b.classList.toggle('sel',b.dataset.r===r);G=null;draw();loadGraph()};
let loading=false;
async function loadGraph(){if(!gStock||loading)return;loading=true;const want=gStock+'|'+gRange;try{const d=await api(`/api/history?stock=${encodeURIComponent(gStock)}&range=${gRange}`);if(want===gStock+'|'+gRange){G=d;lastG=Date.now();draw();updateHead()}}catch(e){}finally{loading=false}}
setInterval(()=>{const fast=['1m','5m','15m','1h'].includes(gRange);if(fast||Date.now()-lastG>(gRange==='all'?30000:10000))loadGraph()},1000);
function updateHead(){const st=stockById(gStock);$('#sym').textContent=st?(st.name||st.id):'-';const isNW=gStock==='__NW';
  const pts=G&&G.points&&G.points.length?G.points:null;const last=st?st.price:(pts?pts[pts.length-1][1]:null);$('#px').textContent=last==null?'-':(isNW?fmtShort(last):fmtP(last));
  const c=$('#chg');const inv=isNW||(st&&(st.owned>0||st.shorted>0));if(inv&&pts&&pts.length>1&&pts[0][1]){const ch=(pts[pts.length-1][1]-pts[0][1])/Math.abs(pts[0][1])*100;c.textContent=pctS(ch);c.className='pill m '+(ch>=0?'up':'down')}else{c.textContent='';c.className='pill m'}}
const UNITS=[[1e27,'Oc'],[1e24,'Sp'],[1e21,'Sx'],[1e18,'Qi'],[1e15,'Qa'],[1e12,'T'],[1e9,'B'],[1e6,'M'],[1e3,'K']];
function axisFmt(v,step,isNW){const a=Math.abs(v);if(isNW||a>=1e5){let u=1,sfx='';for(const[x,y]of UNITS)if(a>=x){u=x;sfx=y;break}const d=Math.min(6,Math.max(0,Math.ceil(-Math.log10(step/u)-1e-9)));return(v/u).toFixed(d)+sfx}return v.toFixed(Math.min(6,Math.max(3,Math.ceil(-Math.log10(step)-1e-9))))}
function niceStep(span,n){const s0=span/n;const mag=Math.pow(10,Math.floor(Math.log10(s0)));return[1,2,2.5,5,10].map(x=>x*mag).find(x=>x>=s0)||10*mag}
const TSTEPS=[1e3,5e3,1e4,15e3,3e4,6e4,12e4,3e5,6e5,9e5,18e5,36e5,72e5,108e5,216e5,432e5,864e5,1728e5,6048e5];
function tfmt(t,step,span){const d=new Date(t);if(step>=864e5)return d.toLocaleDateString([],{month:'short',day:'numeric'});if(step<6e4)return d.toLocaleTimeString([],{hour:'2-digit',minute:'2-digit',second:'2-digit',hour12:false});
  const hm=d.toLocaleTimeString([],{hour:'2-digit',minute:'2-digit',hour12:false});return span>864e5&&d.getHours()===0&&d.getMinutes()===0?d.toLocaleDateString([],{month:'short',day:'numeric'}):hm}
function rr(c,x,y,w,h,r){c.beginPath();c.moveTo(x+r,y);c.arcTo(x+w,y,x+w,y+h,r);c.arcTo(x+w,y+h,x,y+h,r);c.arcTo(x,y+h,x,y,r);c.arcTo(x,y,x+w,y,r);c.closePath()}
function tag(c,x,y,text,bg,fg,left){c.font='600 '+MONO;const w=c.measureText(text).width+10;const X=left?x:x;rr(c,X,y-8,w,16,3);c.fillStyle=bg;c.fill();c.fillStyle=fg;c.textAlign='left';c.textBaseline='middle';c.fillText(text,X+5,y+.5);return w}
function draw(){
  const cv=$('#cv'),box=$('#cbox'),dpr=window.devicePixelRatio||1,W=box.clientWidth,H=box.clientHeight;
  if(cv.width!==Math.round(W*dpr)||cv.height!==Math.round(H*dpr)){cv.width=Math.round(W*dpr);cv.height=Math.round(H*dpr)}
  const c=cv.getContext('2d');c.setTransform(dpr,0,0,dpr,0,0);c.clearRect(0,0,W,H);
  let pts=G&&G.stock===gStock?G.points:[];const isNW=gStock==='__NW';{const cur=stockById(gStock);if(pts.length&&cur&&cur.price!=null&&Date.now()-pts[pts.length-1][0]>1500)pts=pts.concat([[Date.now(),cur.price]])}const f=isNW?fmtShort:fmtP;
  const R=76,B=24,T=24,L=0,pw=W-L-R,ph=H-T-B;
  if(pts.length<2){c.fillStyle=AXIS;c.font='13px Segoe UI, system-ui';c.textAlign='center';c.textBaseline='middle';c.fillText(G?(isNW?'No net worth data for this range yet - it is recorded while StockPilot runs.':'No data for this range yet - it fills in while StockPilot runs.'):'Loading...',W/2,H/2);geo=null;$('#readout').textContent='';$('#legend').innerHTML='';return}
  let lo=Infinity,hi=-Infinity;for(const p of pts){if(p[1]<lo)lo=p[1];if(p[1]>hi)hi=p[1]}
  const first=pts[0][1],last=pts[pts.length-1][1];const _cs=stockById(gStock);const invested=isNW||(_cs&&(_cs.owned>0||_cs.shorted>0));const col=invested?(last>=first?UP:DOWN):GRAYL;
  const st=stockById(gStock);const lines=[];
  if(!isNW&&st){for(const r of rules)if(r.enabled&&r.price>0&&norm(r.stock)===norm(st.name||st.id))lines.push({v:r.price,color:(r.action==='buy'||r.action==='cover')?AQUA:r.action==='close'?'#b9b8b1':DOWN,label:r.action.toUpperCase()+(r.when==='below'?' < ':' > ')+fmtP(r.price),kind:'rule'});
    if(G.owned>0&&G.avgBuy>0)lines.push({v:G.avgBuy,color:BLUE,label:'Avg buy',kind:'avg'});if(G.shorted>0&&G.avgShort>0)lines.push({v:G.avgShort,color:ORANGE,label:'Avg short',kind:'avg'})}
  const span0=(hi-lo)||Math.abs(hi)*0.02||1,off=[];let ylo=lo,yhi=hi;
  for(const l of lines){if(l.v>=lo-span0*0.75&&l.v<=hi+span0*0.75){ylo=Math.min(ylo,l.v);yhi=Math.max(yhi,l.v)}else off.push(l)}
  const pad=(yhi-ylo)*0.07||span0*0.1;ylo-=pad;yhi+=pad;
  const t0=gRange==='all'?pts[0][0]:G.from,t1=Math.max(G.to,pts[pts.length-1][0]);
  const X=t=>L+(t-t0)/((t1-t0)||1)*pw,Y=v=>T+(1-(v-ylo)/((yhi-ylo)||1))*ph;
  // grid + axes
  c.font=MONO;c.lineWidth=1;const ys=niceStep(yhi-ylo,Math.max(4,Math.floor(ph/30)));
  for(let v=Math.ceil(ylo/ys)*ys;v<=yhi;v+=ys){const y=Math.round(Y(v))+.5;c.strokeStyle=GRID;c.beginPath();c.moveTo(L,y);c.lineTo(L+pw,y);c.stroke();c.fillStyle=AXIS;c.textAlign='left';c.textBaseline='middle';c.fillText(axisFmt(v,ys,isNW),L+pw+8,y)}
  const span=t1-t0,tstep=TSTEPS.find(s=>s>=span/Math.max(3,Math.floor(pw/110)))||6048e5,tz=-new Date().getTimezoneOffset()*6e4;
  c.textAlign='center';c.textBaseline='top';for(let t=Math.ceil((t0+tz)/tstep)*tstep-tz;t<=t1;t+=tstep){const x=Math.round(X(t))+.5;c.strokeStyle=GRID;c.beginPath();c.moveTo(x,T);c.lineTo(x,T+ph);c.stroke();if(x>40&&x<L+pw-30){c.fillStyle=AXIS;c.fillText(tfmt(t,tstep,span),x,T+ph+6)}}
  c.strokeStyle='#2a2c33';c.beginPath();c.moveTo(L+pw+.5,T);c.lineTo(L+pw+.5,T+ph);c.moveTo(L,T+ph+.5);c.lineTo(L+pw,T+ph+.5);c.stroke();
  // area + line
  const g=c.createLinearGradient(0,T,0,T+ph);g.addColorStop(0,col===UP?'rgba(134,224,143,.20)':col===DOWN?'rgba(240,113,120,.20)':'rgba(154,156,163,.14)');g.addColorStop(1,'rgba(0,0,0,0)');
  c.beginPath();pts.forEach((p,i)=>{const x=X(p[0]),y=Y(p[1]);i?c.lineTo(x,y):c.moveTo(x,y)});c.lineTo(X(pts[pts.length-1][0]),T+ph);c.lineTo(X(pts[0][0]),T+ph);c.closePath();c.fillStyle=g;c.fill();
  c.beginPath();pts.forEach((p,i)=>{const x=X(p[0]),y=Y(p[1]);i?c.lineTo(x,y):c.moveTo(x,y)});c.strokeStyle=col;c.lineWidth=1.6;c.lineJoin='round';c.stroke();
  // rule + avg lines
  for(const l of lines){if(off.includes(l))continue;const y=Math.round(Y(l.v))+.5;c.setLineDash(l.kind==='avg'?[2,3]:[6,4]);c.strokeStyle=l.color;c.lineWidth=1;c.beginPath();c.moveTo(L,y);c.lineTo(L+pw,y);c.stroke();c.setLineDash([]);
    if(l.kind==='rule')tag(c,L+6,y,l.label,l.color,'#0b0c0f');else{c.font='600 '+MONO;const lw=c.measureText(l.label).width+10;tag(c,L+pw-lw,y,l.label,l.color,'#0b0c0f');tag(c,L+pw+2,y,f(l.v),'#0b0c0f',l.color)}}
  off.forEach((l,k)=>{c.font=MONO;c.fillStyle=AXIS;c.textAlign='left';c.textBaseline='top';c.fillText((l.v>hi?'\u2191 ':'\u2193 ')+l.label+(l.kind==='avg'?' '+f(l.v):'')+' (off chart)',L+8,T+ph-16-k*14)});
  // trades
  const tr=(G.trades||[]).filter(x=>x[0]>=t0&&x[0]<=t1);geo={X,Y,pts,T,ph,L,pw,f,tr,t0,t1};
  for(const x of tr){const px=X(x[0]),py=Y(x[3]),b=x[1]==='buy'||x[1]==='cover',cl=b?UP:DOWN;c.beginPath();if(b){c.moveTo(px,py+5);c.lineTo(px-5,py+13);c.lineTo(px+5,py+13)}else{c.moveTo(px,py-5);c.lineTo(px-5,py-13);c.lineTo(px+5,py-13)}c.closePath();
    if(x[4]==='bot'){c.fillStyle=cl;c.fill()}else{c.strokeStyle=cl;c.lineWidth=1.5;c.stroke()}}
  // current price
  const ly=Math.round(Y(last))+.5;c.setLineDash([1,3]);c.strokeStyle=col;c.lineWidth=1;c.beginPath();c.moveTo(L,ly);c.lineTo(L+pw,ly);c.stroke();c.setLineDash([]);tag(c,L+pw+2,ly,f(last),col,'#0b0c0f');
  // date tag
  const d0=new Date(pts[0][0]);c.font=MONO;const ds=d0.toLocaleDateString([],{day:'numeric',month:'short',year:'2-digit'})+'  '+d0.toLocaleTimeString([],{hour12:false});const dw=c.measureText(ds).width+10;c.fillStyle='#202228';c.fillRect(L,T+ph+1,dw,B-2);c.fillStyle=AXIS;c.textAlign='left';c.textBaseline='middle';c.fillText(ds,L+5,T+ph+B/2);
  // hover
  let ro='';if(hover){const mx=Math.min(Math.max(hover.x,L),L+pw);let a=0,z=pts.length-1;while(z-a>1){const m=(a+z)>>1;if(X(pts[m][0])<mx)a=m;else z=m}const p=Math.abs(X(pts[a][0])-mx)<Math.abs(X(pts[z][0])-mx)?pts[a]:pts[z];
    const x=Math.round(X(p[0]))+.5,my=Math.min(Math.max(hover.y,T),T+ph);c.setLineDash([3,3]);c.strokeStyle='#5a5c66';c.beginPath();c.moveTo(x,T);c.lineTo(x,T+ph);c.moveTo(L,Math.round(my)+.5);c.lineTo(L+pw,Math.round(my)+.5);c.stroke();c.setLineDash([]);
    c.fillStyle=col;c.beginPath();c.arc(x,Y(p[1]),3.5,0,7);c.fill();tag(c,L+pw+2,my,f(ylo+(1-(my-T)/ph)*(yhi-ylo)),'#3a3c45','#ecebe7');
    const dt=new Date(p[0]);const ts=dt.toLocaleDateString([],{month:'numeric',day:'numeric'})+', '+dt.toLocaleTimeString();c.font=MONO;const tw=c.measureText(ts).width+10;rr(c,Math.min(Math.max(x-tw/2,L),L+pw-tw),T+ph+2,tw,B-4,3);c.fillStyle='#3a3c45';c.fill();c.fillStyle='#ecebe7';c.textAlign='left';c.textBaseline='middle';c.fillText(ts,Math.min(Math.max(x-tw/2,L),L+pw-tw)+5,T+ph+B/2);
    ro=`${esc(ts)}<b>${esc(f(p[1]))}</b>`;const near=tr.find(t=>Math.abs(X(t[0])-mx)<7);if(near)ro+=`<b class="${near[1]==='buy'||near[1]==='cover'?'up':'down'}">${near[1].toUpperCase()} ${fmtShort(near[2])} @ ${fmtP(near[3])} \u00b7 ${near[4]}</b>`}
  $('#readout').innerHTML=ro;
  $('#legend').innerHTML=(lines.length||tr.length)?(lines.filter(l=>l.kind==='rule').length?`<span><i style="border-color:${AQUA}"></i>buy / cover</span><span><i style="border-color:${DOWN}"></i>sell / short</span>`:'')+(lines.some(l=>l.kind==='avg')?`<span><i style="border-color:${BLUE};border-top-style:dotted"></i>your average price</span>`:'')+(tr.length?'<span>\u25b2\u25bc trades (filled = bot, outline = you)</span>':''):'';
}
$('#cbox').addEventListener('mousemove',e=>{const r=$('#cbox').getBoundingClientRect();hover={x:e.clientX-r.left,y:e.clientY-r.top};draw()});
$('#cbox').addEventListener('mouseleave',()=>{hover=null;draw()});
window.addEventListener('resize',draw);
$('#csv').onclick=()=>{if(!G||!G.points.length)return;const st=stockById(gStock);const name=(st?(st.name||st.id):gStock).replace(/[^A-Za-z0-9_-]/g,'');
  const rows=['time,price'].concat(G.points.map(p=>new Date(p[0]).toISOString()+','+p[1]));const a=document.createElement('a');a.href=URL.createObjectURL(new Blob([rows.join('\n')],{type:'text/csv'}));
  const d=new Date();a.download=`${name}_${gRange}_${d.getFullYear()}${String(d.getMonth()+1).padStart(2,'0')}${String(d.getDate()).padStart(2,'0')}-${String(d.getHours()).padStart(2,'0')}${String(d.getMinutes()).padStart(2,'0')}.csv`;a.click()};

/* profit */
function renderProfitHero(){if(!S)return;const p=S.todayProfit;$('#pHero').textContent=p==null?'-':signed(p);$('#pHero').className='hero m '+(p>0?'up':p<0?'down':'');
  $('#pSub').textContent=S.todayStart==null?'Starts tracking once the game is connected.':`started at ${fmtShort(S.todayStart)} \u2192 now ${fmtShort(S.netWorth)}`+(S.todayStart>0&&p!=null?`  (${pctS(p/S.todayStart*100)})`:'')}
async function loadDaily(){if(tab!=='profit')return;try{daily=await api('/api/daily');renderDaily()}catch(e){}}
setInterval(loadDaily,20000);
function renderDaily(){const rows=daily.slice(0,14).reverse(),bars=$('#bars'),labs=$('#blabels');
  if(!rows.length){bars.innerHTML='<div class="empty" style="flex:1">No days recorded yet.</div>';labs.innerHTML='';$('#ptab').innerHTML='';return}
  const mx=Math.max(...rows.map(r=>Math.max(r.profit,0)),0),mn=Math.min(...rows.map(r=>Math.min(r.profit,0)),0),span=(mx-mn)||1,zt=mx/span*100;
  bars.innerHTML=`<div class="zero" style="top:${zt}%"></div>`+rows.map((r,i)=>{const h=Math.abs(r.profit)/span*100,pos=r.profit>=0;
    return`<div class="bar2" data-i="${i}"><i style="${pos?`bottom:${100-zt}%;height:${h}%;background:${UP};border-radius:4px 4px 0 0`:`top:${zt}%;height:${h}%;background:${DOWN};border-radius:0 0 4px 4px`};min-height:${r.profit?2:0}px"></i></div>`}).join('');
  labs.innerHTML=rows.map((r,i)=>`<span>${i===rows.length-1||i%3===0?r.date.slice(5).replace('-','/'):''}</span>`).join('');
  bars.onmousemove=e=>{const b=e.target.closest('.bar2'),tip=$('#btip');if(!b){tip.style.display='none';return}const r=rows[+b.dataset.i];tip.innerHTML=`<b>${r.date}</b><br><span class="m">${signed(r.profit)}</span>`;tip.style.display='block';
    const br=b.getBoundingClientRect(),cr=bars.closest('.card').getBoundingClientRect();tip.style.left=Math.min(br.left-cr.left,cr.width-tip.offsetWidth-4)+'px';tip.style.top=(br.top-cr.top-4)+'px'};
  bars.onmouseleave=()=>{$('#btip').style.display='none'};
  $('#ptab').innerHTML=daily.map(r=>`<tr><td>${r.date}</td><td class="m">${fmtShort(r.start)}</td><td class="m">${fmtShort(r.last)}</td><td class="m ${r.profit>0?'up':r.profit<0?'down':''}">${signed(r.profit)}</td></tr>`).join('')}

/* calculator */
function calc(src){const s=String(src).replace(/\s+/g,'').replace(/,/g,'').replace(/\u00d7/g,'*').replace(/(\d|\))x(?=[\d(.])/gi,'$1*').replace(/\u00f7/g,'/').replace(/\u2212/g,'-');let i=0;if(!s)return null;
  const num=()=>{const m=/^(\d+\.?\d*|\.\d+)(e[+-]?\d+)?(qa|qi|sx|sp|oc|[kmbt])?/i.exec(s.slice(i));if(!m)throw 0;i+=m[0].length;const v=parseFloat(m[1]+(m[2]||''));const u={k:1e3,m:1e6,b:1e9,t:1e12,qa:1e15,qi:1e18,sx:1e21,sp:1e24,oc:1e27}[(m[3]||'').toLowerCase()];return u?v*u:v};
  const post=v=>{while(s[i]==='%'){i++;v/=100}return v};
  const prim=()=>{const ch=s[i];if(ch==='('){i++;const v=expr();if(s[i]!==')')throw 0;i++;return post(v)}if(ch==='-'){i++;return-prim()}if(ch==='+'){i++;return prim()}return post(num())};
  const pw=()=>{let v=prim();if(s[i]==='^'){i++;v=Math.pow(v,pw())}return v};
  const term=()=>{let v=pw();while(s[i]==='*'||s[i]==='/'){const o=s[i++];const r=pw();v=o==='*'?v*r:v/r}return v};
  const expr=()=>{let v=term();while(s[i]==='+'||s[i]==='-'){const o=s[i++];const r=term();v=o==='+'?v+r:v-r}return v};
  const v=expr();if(i!==s.length)throw 0;return v}
function showCalc(){const out=$('#cres');try{const v=calc($('#cin').value);out.innerHTML=v==null?'':`${fmtFull(v)}<small>${Math.abs(v)>=1e3?fmtShort(v):''}</small>`}catch(e){out.innerHTML='<small>...</small>'}}
$('#cin').addEventListener('input',showCalc);
$('#cin').addEventListener('keydown',e=>{if(e.key==='Enter'){try{const v=calc($('#cin').value);if(v!=null){$('#cin').value=String(+v.toPrecision(12));showCalc()}}catch(x){}}});
const KEYS=['C','(',')','\u00f7','7','8','9','\u00d7','4','5','6','\u2212','1','2','3','+','0','.','%','=','K','M','B','T','Qa','Qi','Sx','Sp','Oc','^','00','\u232b'];
$('#keys').innerHTML=KEYS.map(k=>`<button data-k="${k}" class="${'\u00f7\u00d7\u2212+%()^'.includes(k)?'op':k==='='?'eq':''}">${k}</button>`).join('');
$('#keys').onclick=e=>{const k=e.target.dataset.k;if(!k)return;const inp=$('#cin');
  if(k==='C')inp.value='';else if(k==='\u232b')inp.value=inp.value.slice(0,-1);else if(k==='='){try{const v=calc(inp.value);if(v!=null)inp.value=String(+v.toPrecision(12))}catch(x){}}
  else inp.value+=({'\u00f7':'/','\u00d7':'*','\u2212':'-'}[k]||k.toLowerCase());showCalc();inp.focus()};
function renderCalcChips(){if(!S)return;const st=stockById(gStock);const items=[['Cash',S.cash],['Net worth',S.netWorth]];if(st&&st.id!=='__NW')items.push([(st.name||st.id)+' price',st.price]);
  $('#cchips').innerHTML=items.filter(x=>x[1]!=null).map(([n,v])=>`<button class="chip" data-v="${v}"><span class="t">${esc(n)}</span> <span class="m">${fmtShort(v)}</span></button>`).join('')}
$('#cchips').onclick=e=>{const b=e.target.closest('.chip');if(!b)return;const inp=$('#cin');inp.value+=String(+(+b.dataset.v).toPrecision(12));showCalc();inp.focus()};
function helper(){const g=id=>{try{return calc($(id).value)}catch(e){return null}};const b=g('#hB'),s=g('#hS'),m=g('#hM');
  if(!(b>0)||s==null||!(m>0)){['#hSh','#hP','#hR'].forEach(x=>$(x).textContent='-');return}const sh=m/b,p=sh*(s-b);$('#hSh').textContent=fmtShort(sh);$('#hP').textContent=signed(p);$('#hR').textContent=pctS((s-b)/b*100)}
['#hB','#hS','#hM'].forEach(id=>$(id).addEventListener('input',helper));
poll();setTimeout(loadGraph,400);
</script></body></html>
'@

# --------------------------------------------------------------------- main
[void][IO.Directory]::CreateDirectory($DataDir)
if ($IsWin) {
    $elevated = $false
    try { $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }
    $exe = Join-Path $Here 'StockPilot.exe'
    if ($elevated -and (Test-Path -LiteralPath $exe) -and -not $env:SSBOT_ALLOW_ADMIN) {
        # StockPilot doesn't need admin, and an admin copy can't be stopped or reached by normal programs.
        try { Start-Process (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList ('"' + $exe + '"'); return } catch { }
    }
}
function Show-Box($text) {
    if (-not $IsWin) { return }
    try { Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.MessageBox]::Show($text, 'StockPilot', 'OK', 'Warning') } catch { }
}
try { if ((Test-Path -LiteralPath $LogFile) -and (Get-Item -LiteralPath $LogFile).Length -gt 1MB) { Remove-Item -LiteralPath $LogFile -Force } } catch { }
Say "StockPilot $Version" Cyan
Say "Game folder: $GameDir" Gray
$mtxName = 'StockPilot_single'; if ($env:SSBOT_INSTANCE) { $mtxName += '_' + $env:SSBOT_INSTANCE }   # test copies side by side
$global:Mtx = New-Object System.Threading.Mutex($false, $mtxName)
$got = $false
try { $got = $global:Mtx.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
if (-not $got) {
    $old = $null; try { $old = ([IO.File]::ReadAllText((Join-Path $DataDir 'port.txt'))).Trim() } catch { }
    $alive = $false
    if ($old) { try { $rq = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$old/api/state"); $rq.Timeout = 3000; $rs = $rq.GetResponse(); $rs.Close(); $alive = $true } catch { } }
    if ($alive) {
        if (-not $env:SSBOT_NOOPEN) {
            if ($IsWin) { try { Add-Type -TypeDefinition $PinCode -Language CSharp; $global:PinOk = $true } catch { } }
            $st = Read-Json (Join-Path $DataDir 'settings.json'); if ($st -and $st.onTop -eq $false) { $global:Settings.pin = $false }
            if ((Do-Focus) -eq 0) { Open-Panel "http://127.0.0.1:$old/" }
        }
        Say 'Already running.' Gray
        return
    }
    # the other copy holds the lock but doesn't answer: stop it (same user) and take over
    $stopped = 0
    try {
        if ($IsWin) {
            Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and ($_.CommandLine -like '*StockPilot.ps1*' -or $_.CommandLine -like '*FantaStocks.ps1*') } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; $stopped++ } catch { } }
        } else {
            Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID -and $_.CommandLine -and ($_.CommandLine -like '*StockPilot.ps1*' -or $_.CommandLine -like '*FantaStocks.ps1*') } | ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction Stop; $stopped++ } catch { } }
        }
    } catch { }
    if ($stopped) { try { $got = $global:Mtx.WaitOne(5000) } catch [System.Threading.AbandonedMutexException] { $got = $true } }
    if (-not $got) {
        Say 'Another StockPilot is running but not answering, and it could not be stopped (probably started as administrator).' Red
        if (-not $Background) { Show-Box ("StockPilot is already running in the background, but this copy can't reach or stop it." + [Environment]::NewLine + [Environment]::NewLine + "This happens when it was started with 'Run as administrator'. Restart your PC, then open StockPilot normally (it never needs admin).") }
        return
    }
    Say "Stopped a stuck StockPilot and took over." Yellow
}
if (-not (Test-Path -LiteralPath $Rules)) {
    Save-Rules $true (New-Object System.Collections.ArrayList)
    Say 'Started with no auto actions (practice mode) - add your own in the panel.' Green
}
if (-not (Apply-Rules)) { $global:Doc = @{ dry = $true; rules = (New-Object System.Collections.ArrayList) }; $global:Active = @() }
Say ('Mode: ' + (Mode-Name) + ' - ' + @($global:Active).Count + ' active auto actions') Cyan
try { Add-Type -TypeDefinition $FastCode -ErrorAction Stop; $global:FastIO = $true } catch { Say "Fast history reader unavailable (using the slower one): $($_.Exception.Message)" Yellow }
try { Load-Saved } catch { Say "Couldn't load saved chart data: $($_.Exception.Message)" Yellow }
try { Compact-Old } catch { }
Load-Settings
if ($global:Settings.awake) { Set-Awake $true }
if ($Background -and $global:Settings.autoGame) { $global:AutoGameAt = (Get-Date).AddSeconds(20) }
if ($IsWin) { try { Add-Type -TypeDefinition $PinCode -Language CSharp; $global:PinOk = $true } catch { Say "Window helper unavailable (the launcher handles the window instead): $($_.Exception.Message)" Gray } }

$global:Token = [guid]::NewGuid().ToString('N')
$global:Listener = $null; $global:Port = 0; $lerr = ''
foreach ($p in 47811..47830) {
    try { $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $p); $l.ExclusiveAddressUse = $true; $l.Start(); $global:Listener = $l; $global:Port = $p; break } catch { $lerr = $_.Exception.Message }
}
if ($global:Listener) {
    [IO.File]::WriteAllText((Join-Path $DataDir 'port.txt'), "$($global:Port)")
    if (-not $env:SSBOT_NOOPEN) { Open-Panel "http://127.0.0.1:$($global:Port)/" }
    $global:PinUntil = (Get-Date).AddSeconds(30)
    Say "Panel running at http://127.0.0.1:$($global:Port)/" Green
} else {
    Say "Couldn't start the panel ($lerr) - the bot still runs." Yellow
}

try { Cover-Load } catch { Say "Couldn't load the coverage list: $($_.Exception.Message)" Yellow }
try { Anim-Load } catch { }
Share-LoadQueue
$nextTick = Get-Date; $nextPin = Get-Date; $nextShare = Get-Date
while (-not $global:Quit) {
    try {
        if ($global:Listener) { Poll-Clients }
        $now = Get-Date
        if ($now -ge $nextTick) { $nextTick = $now.AddMilliseconds(100); Tick }
        if ($now -ge $nextShare) { $nextShare = $now.AddMilliseconds(500); try { Share-Step } catch { Say "Shared tracking error: $($_.Exception.Message)" Yellow; $global:Share.req = $null } }
        try { Anim-Step } catch { }
        if ($global:PinOk -and $now -lt $global:PinUntil -and $now -ge $nextPin) {
            $nextPin = $now.AddSeconds(1)
            if ((Do-Focus) -gt 0) { $global:PinUntil = [DateTime]::MinValue }
        }
        if ($global:Pending.Count -eq 0) { Start-Sleep -Milliseconds 30 }
    } catch {
        Say "Error: $($_.Exception.Message)" Red
        Start-Sleep -Milliseconds 500
    }
}
try { Flush-Writes } catch { }
try { Share-SaveQueue; Cover-Save; Save-Settings } catch { }
try { Save-Daily } catch { }
try { $global:Listener.Stop() } catch { }
try { $global:Mtx.ReleaseMutex() } catch { }
