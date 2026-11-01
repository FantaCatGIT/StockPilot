'use strict';
// StockPilot 2 - desktop app shell (window, tray, notifications, Windows integration)
const { app, BrowserWindow, ipcMain, Tray, Menu, nativeImage, shell, Notification, powerSaveBlocker, nativeTheme, screen, net, dialog } = require('electron');
const path = require('path');
const fs = require('fs');
const { exec } = require('child_process');
const { Engine } = require('./backend/core');
const { migrateFromV1, oldDirs } = require('./backend/migrate');

// startup problems are written to <data>\error.log and shown in a message box instead of failing silently
function logError(where, e) {
  const msg = `${new Date().toISOString()} [${where}] ${(e && e.stack) || e}\n`;
  try { const d = app.getPath('userData'); fs.mkdirSync(d, { recursive: true }); fs.appendFileSync(path.join(d, 'error.log'), msg); } catch (_) { }
  return msg;
}
let startupDone = false;
process.on('uncaughtException', e => { const m = logError('main', e); if (!startupDone) { try { dialog.showErrorBox('StockPilot could not start', m); } catch (_) { } } });
app.on('child-process-gone', (_e, d) => logError('child', `${d.type} ${d.reason} (${d.exitCode})`));
app.on('render-process-gone', (_e, _w, d) => logError('window', `${d.reason} (${d.exitCode})`));

app.setAppUserModelId('com.stockpilot.app');
if (process.env.STOCKPILOT_USERDATA) app.setPath('userData', process.env.STOCKPILOT_USERDATA);
const gotLock = app.requestSingleInstanceLock();
const startHidden = process.argv.some(a => a === '--hidden' || a.toLowerCase() === '/background');
let win = null, tray = null, engine = null, quitting = false, awakeId = null, trayHinted = false;
const ICON = path.join(__dirname, 'build', process.platform === 'win32' ? 'icon.ico' : 'icon.png');

function showWindow() {
  if (!win) createWindow(true);
  else { if (win.isMinimized()) win.restore(); win.show(); win.focus(); }
}

function createWindow(show) {
  const s = engine.settings;
  let b = { width: 1440, height: 920 };
  if (s.window && s.window.width > 600) {
    const area = screen.getDisplayMatching(s.window).workArea;
    const inside = s.window.x + 60 < area.x + area.width && s.window.y + 40 < area.y + area.height && s.window.x + s.window.width > area.x + 60 && s.window.y >= area.y - 20;
    if (inside) b = s.window;
  }
  win = new BrowserWindow({
    ...b, minWidth: 1000, minHeight: 640, show: false, title: 'StockPilot', icon: ICON,
    backgroundColor: themeIsDark() ? '#0f1115' : '#f4f6fa', autoHideMenuBar: true,
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false, sandbox: true, spellcheck: false, backgroundThrottling: false },
  });
  win.setMenu(null);
  if (s.window && s.window.max) win.maximize();
  win.loadFile(path.join(__dirname, 'ui', 'index.html'));
  win.once('ready-to-show', () => { if (show) win.show(); });
  let saveT = null;
  const saveBounds = () => { clearTimeout(saveT); saveT = setTimeout(() => { if (!win || win.isMinimized()) return; const nb = win.isMaximized() ? Object.assign({}, engine.settings.window || win.getNormalBounds(), { max: true }) : Object.assign(win.getBounds(), { max: false }); engine.setSettings({ window: nb }); }, 600); };
  win.on('resize', saveBounds); win.on('move', saveBounds);
  win.on('close', e => {
    if (!quitting && engine.settings.closeToTray) {
      e.preventDefault(); win.hide();
      if (!trayHinted && Notification.isSupported()) { trayHinted = true; new Notification({ title: 'StockPilot is still running', body: 'It keeps recording and trading in the background. Right-click the tray icon to quit.', icon: ICON, silent: true }).show(); }
    }
  });
  win.on('closed', () => { win = null; });
  win.webContents.setWindowOpenHandler(({ url }) => { if (/^https?:\/\//.test(url)) shell.openExternal(url); return { action: 'deny' }; });
  win.webContents.on('will-navigate', (e, url) => { if (!url.startsWith('file://')) { e.preventDefault(); if (/^https?:\/\//.test(url)) shell.openExternal(url); } });
  win.setAlwaysOnTop(!!s.alwaysOnTop);
}

function themeIsDark() { const t = engine ? engine.settings.theme : 'light'; return t === 'dark' || (t === 'system' && nativeTheme.shouldUseDarkColors); }

function applySettings(s) {
  nativeTheme.themeSource = s.theme === 'dark' ? 'dark' : s.theme === 'system' ? 'system' : 'light';
  if (win) { win.setAlwaysOnTop(!!s.alwaysOnTop); win.setBackgroundColor(themeIsDark() ? '#0f1115' : '#f4f6fa'); }
  if (s.keepAwake && awakeId === null) awakeId = powerSaveBlocker.start('prevent-app-suspension');
  if (!s.keepAwake && awakeId !== null) { powerSaveBlocker.stop(awakeId); awakeId = null; }
  if (app.isPackaged && (process.platform === 'win32' || process.platform === 'darwin')) {
    try { app.setLoginItemSettings({ openAtLogin: !!s.startWithWindows, path: process.execPath, args: ['--hidden'], name: 'StockPilot' }); } catch (e) { }
  } else if (app.isPackaged && process.platform === 'linux') linuxAutostart(!!s.startWithWindows);
  buildTray();
}

// Linux has no login-item API: use an XDG autostart entry (the launcher script sets STOCKPILOT_LAUNCHER)
function linuxAutostart(on) {
  const dir = path.join(app.getPath('home'), '.config', 'autostart'), f = path.join(dir, 'stockpilot.desktop');
  try {
    if (!on) { if (fs.existsSync(f)) fs.unlinkSync(f); return; }
    const exe = process.env.STOCKPILOT_LAUNCHER || process.execPath;
    const extra = !process.env.STOCKPILOT_LAUNCHER && process.argv.includes('--no-sandbox') ? ' --no-sandbox' : '';
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(f, `[Desktop Entry]\nType=Application\nName=StockPilot\nComment=StockPilot for Screen Stocks\nExec="${exe}"${extra} --hidden\nIcon=stockpilot\nTerminal=false\nX-GNOME-Autostart-enabled=true\n`);
  } catch (e) { }
}

function buildTray() {
  if (!tray) {
    let img = nativeImage.createFromPath(ICON);
    if (process.platform !== 'win32') img = img.resize({ width: 18, height: 18 });
    tray = new Tray(img); tray.setToolTip('StockPilot');
    tray.on('click', showWindow); tray.on('double-click', showWindow);
  }
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: 'Open StockPilot', click: showWindow },
    { label: engine.paused ? 'Resume auto trading' : 'Pause auto trading', click: () => { engine.setPaused(!engine.paused); buildTray(); } },
    { label: 'Open Screen Stocks', click: () => engine.launchGame() },
    { type: 'separator' },
    { label: 'Quit StockPilot', click: () => { quitting = true; app.quit(); } },
  ]));
}

// stop StockPilot 1.x (PowerShell) if it is still running - two bots would trade twice
function stopOldVersion() {
  if (process.platform !== 'win32') return;
  if (!oldDirs().some(d => fs.existsSync(path.join(d, 'StockPilot.ps1')) || fs.existsSync(path.join(d, 'FantaStocks.ps1')))) return;
  const ps = "Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and ($_.CommandLine -like '*StockPilot.ps1*' -or $_.CommandLine -like '*FantaStocks.ps1*' -or $_.CommandLine -like '*SSBOT_SELF*') } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }";
  exec('powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -Command "' + ps.replace(/"/g, '\\"') + '"', { windowsHide: true, timeout: 20000 }, () => { });
}

// Windows only shows our notifications / groups the taskbar icon when the Start menu shortcut carries our app id
function fixStartMenuShortcut() {
  if (process.platform !== 'win32' || !app.isPackaged) return;
  try {
    const lnk = path.join(app.getPath('appData'), 'Microsoft', 'Windows', 'Start Menu', 'Programs', 'StockPilot.lnk');
    if (!fs.existsSync(lnk)) { shell.writeShortcutLink(lnk, 'create', { target: process.execPath, appUserModelId: 'com.stockpilot.app', icon: fs.existsSync(path.join(path.dirname(process.execPath), 'icon.ico')) ? path.join(path.dirname(process.execPath), 'icon.ico') : process.execPath, iconIndex: 0, description: 'StockPilot for Screen Stocks' }); return; }
    const cur = shell.readShortcutLink(lnk);
    if (cur.appUserModelId !== 'com.stockpilot.app') shell.writeShortcutLink(lnk, 'update', { appUserModelId: 'com.stockpilot.app' });
  } catch (e) { }
}

function api() {
  const e = engine, sk = e.skins;
  return {
    state: () => e.state(),
    history: (sid, range) => e.history(sid, range),
    compare: (ids, range) => e.compare(ids, range),
    trade: (sid, action, pct) => e.trade(sid, action, pct),
    setAuto: (dry, rules) => e.setAuto(dry, rules),
    setPaused: b => { const r = e.setPaused(b); buildTray(); return r; },
    setSettings: p => e.setSettings(p),
    botSet: p => e.botSet(p),
    news: () => e.newsList(),
    refreshNews: () => e.refreshNews(),
    journal: () => e.journal(),
    setNote: (d, t) => e.setNote(d, t),
    stats: () => e.stats(),
    skins: () => sk.list(),
    skinAdd: (meta, b64) => sk.addStatic(meta, b64),
    skinAnimStart: meta => sk.animStart(meta),
    skinAnimFrame: (base, i, b64) => sk.animFrame(base, i, b64),
    skinAnimFinish: (base, n) => sk.animFinish(base, n),
    skinSet: (f, on) => sk.setEnabled(f, on),
    skinDel: f => sk.remove(f),
    launchGame: () => e.launchGame(),
    openFolder: which => shell.openPath(which === 'game' ? e.gameDir : which === 'skins' ? e.p.skins : e.dataDir),
    openUrl: url => { if (/^https?:\/\//.test(String(url))) shell.openExternal(String(url)); },
    quit: () => { quitting = true; app.quit(); },
    version: () => ({ app: app.getVersion(), electron: process.versions.electron, platform: process.platform, arch: process.arch }),
  };
}

if (!gotLock) { app.quit(); }
else {
  app.on('second-instance', () => showWindow());
  app.whenReady().then(() => { try { startApp(); startupDone = true; } catch (e) { const m = logError('startup', e); dialog.showErrorBox('StockPilot could not start', m); app.exit(1); } });
  function startApp() {
    // macOS needs an app menu for Quit and copy/paste shortcuts; Windows/Linux use no menu bar
    Menu.setApplicationMenu(process.platform === 'darwin' ? Menu.buildFromTemplate([{ role: 'appMenu' }, { role: 'editMenu' }, { role: 'windowMenu' }]) : null);
    const dataDir = app.getPath('userData');
    stopOldVersion();
    const early = [];
    const mig = migrateFromV1(dataDir, (m, k) => early.push([m, k]));
    engine = new Engine({ dataDir, version: app.getVersion(), fetchFn: (u, o) => net.fetch(u, o) });
    for (const [m, k] of early) engine.say(m, k);
    if (mig && mig.patch) engine.setSettings(mig.patch);
    engine.on('notify', n => { if (!Notification.isSupported()) return; const x = new Notification({ title: n.title, body: n.body || '', icon: ICON }); x.on('click', showWindow); x.show(); });
    engine.on('openExternal', u => shell.openExternal(u));
    engine.on('settings', s => applySettings(s));
    engine.start();
    applySettings(engine.settings);
    const fns = api();
    ipcMain.handle('sp', async (_e, method, args) => {
      const f = fns[method]; if (!f) throw new Error('Unknown call ' + method);
      return await f(...(args || []));
    });
    fixStartMenuShortcut();
    createWindow(!startHidden);
    // push live state ~1x/s (more often right after the game writes new prices)
    let lastPush = 0, queued = false;
    const push = () => { lastPush = Date.now(); queued = false; if (win && win.isVisible() && !win.webContents.isLoading()) win.webContents.send('state', engine.state()); };
    setInterval(() => { if (Date.now() - lastPush > 900) push(); }, 250);
    engine.on('market', () => { if (queued) return; const wait = Math.max(0, 300 - (Date.now() - lastPush)); queued = true; setTimeout(push, wait); });
  }
  app.on('window-all-closed', () => { if (!engine || !engine.settings.closeToTray) { quitting = true; app.quit(); } });
  app.on('before-quit', () => { quitting = true; if (engine) engine.stop(); });
  app.on('activate', showWindow);
}
