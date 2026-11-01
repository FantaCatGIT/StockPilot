'use strict';
// First run of StockPilot 2: bring over everything from StockPilot 1.x (PowerShell version).
// 1.x kept its data next to the program: %LOCALAPPDATA%\Programs\StockPilot\SSPanelData + ScreenStocksRules.json
const fs = require('fs');
const path = require('path');
const os = require('os');
const { readJson, writeJson, mkdirp } = require('./util');

function copyTree(src, dst) {
  let n = 0;
  if (!fs.existsSync(src)) return 0;
  const st = fs.statSync(src);
  if (st.isDirectory()) { mkdirp(dst); for (const f of fs.readdirSync(src)) n += copyTree(path.join(src, f), path.join(dst, f)); }
  else if (!fs.existsSync(dst)) { fs.copyFileSync(src, dst); n++; }
  return n;
}

function oldDirs() {
  const local = process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local');
  const out = [path.join(local, 'Programs', 'StockPilot'), path.join(local, 'Programs', 'FantaStocks')];
  if (process.platform === 'darwin') out.push(path.join(os.homedir(), 'Library', 'Application Support', 'StockPilot'));
  if (process.env.STOCKPILOT_OLD_DIR) out.unshift(process.env.STOCKPILOT_OLD_DIR);
  return out;
}

function migrateFromV1(dataDir, log = () => { }) {
  const marker = path.join(dataDir, 'migrated-v1.json');
  if (fs.existsSync(marker)) return null;
  const summary = { at: Date.now(), from: null, files: 0, rules: 0 };
  let patch = null;
  for (const dir of oldDirs()) {
    const sd = path.join(dir, 'SSPanelData'), rules = path.join(dir, 'ScreenStocksRules.json');
    if (!fs.existsSync(sd) && !fs.existsSync(rules)) continue;
    summary.from = dir;
    try {
      summary.files += copyTree(path.join(sd, 'history'), path.join(dataDir, 'history'));
      for (const f of ['names.json', 'coverage.txt', 'share-queue.txt']) summary.files += copyTree(path.join(sd, f), path.join(dataDir, f));
      summary.files += copyTree(path.join(sd, 'anim'), path.join(dataDir, 'anim'));
      summary.files += copyTree(path.join(sd, 'skin-thumbs'), path.join(dataDir, 'skin-thumbs'));
      const od = readJson(path.join(sd, 'daily.json'));
      if (od) { const nd = readJson(path.join(dataDir, 'daily.json')) || {}; for (const k of Object.keys(od)) if (!nd[k]) nd[k] = od[k]; writeJson(path.join(dataDir, 'daily.json'), nd); }
      const os1 = readJson(path.join(sd, 'settings.json'));
      if (os1) {
        patch = { share: {} };
        if (os1.onTop !== undefined) patch.alwaysOnTop = !!os1.onTop;
        if (os1.autoGame !== undefined) patch.openGameOnStart = !!os1.autoGame;
        if (os1.awake !== undefined) patch.keepAwake = !!os1.awake;
        if (os1.share === false) patch.share.on = false;
        if (os1.shareUrl) patch.share.url = String(os1.shareUrl);
        if (/^[A-Za-z0-9-]{8,64}$/.test(String(os1.shareId || ''))) patch.share.id = String(os1.shareId);
        if (os1.clockOff !== undefined) patch.share.clockOff = +os1.clockOff || 0;
      }
      const auto = path.join(dataDir, 'automation.json');
      const r = readJson(rules);
      if (r && !fs.existsSync(auto)) { writeJson(auto, { dry_run: r.dry_run !== false, rules: Array.isArray(r.rules) ? r.rules : [] }); summary.rules = (r.rules || []).length; }
    } catch (e) { log('Could not copy everything from the old version: ' + e.message, 'warn'); }
    break;
  }
  // the installer leaves this flag when 1.x was set to start with Windows (its Startup shortcut is removed)
  const flag = path.join(dataDir, 'v1-autostart.flag');
  if (fs.existsSync(flag)) { patch = patch || {}; patch.startWithWindows = true; try { fs.unlinkSync(flag); } catch (e) { } }
  try { writeJson(marker, summary); } catch (e) { }
  if (summary.from) log(`Brought over your StockPilot 1.x data (${summary.files} files, ${summary.rules} auto actions).`, 'ok');
  return { summary, patch };
}

module.exports = { migrateFromV1, oldDirs };
