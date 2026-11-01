'use strict';
// where Screen Stocks keeps its files on Windows / macOS / Linux (Proton)
const path = require('path');
const os = require('os');
const fs = require('fs');

const APP_ID = 4356780;
const SAV_NAME = 'thesmallshort_online_settings.sav';

function candidates() {
  const home = os.homedir();
  const out = [];
  if (process.env.USERPROFILE) out.push(path.join(process.env.USERPROFILE, 'AppData', 'LocalLow', 'Conradical Games', 'Screen Stocks'));
  out.push(path.join(home, 'AppData', 'LocalLow', 'Conradical Games', 'Screen Stocks'));
  out.push(path.join(home, 'Library', 'Application Support', 'Conradical Games', 'Screen Stocks'));
  const tail = path.join('steamapps', 'compatdata', String(APP_ID), 'pfx', 'drive_c', 'users', 'steamuser', 'AppData', 'LocalLow', 'Conradical Games', 'Screen Stocks');
  for (const r of ['.local/share/Steam', '.steam/steam', '.var/app/com.valvesoftware.Steam/.local/share/Steam']) out.push(path.join(home, r, tail));
  return [...new Set(out)];
}

function findGameDir(override) {
  if (override) return override;
  if (process.env.STOCKPILOT_GAMEDIR) return process.env.STOCKPILOT_GAMEDIR;
  const c = candidates();
  for (const d of c) { try { if (fs.existsSync(path.join(d, SAV_NAME)) || fs.existsSync(path.join(d, 'mods'))) return d; } catch (e) { } }
  if (process.platform === 'win32') return c[0];
  if (process.platform === 'darwin') return c.find(d => d.includes('Library')) || c[0];
  return c.find(d => d.includes('compatdata')) || c[0];
}

function gamePaths(gameDir) {
  const mods = path.join(gameDir, 'mods');
  return {
    gameDir,
    sav: path.join(gameDir, SAV_NAME),
    mods,
    modSettings: path.join(mods, 'mod-settings.json'),
    market: path.join(mods, 'export', 'market.json'),
    history: path.join(mods, 'export', 'history.json'),
    commands: path.join(mods, 'commands'),
    skins: path.join(mods, 'skins'),
  };
}

module.exports = { APP_ID, SAV_NAME, findGameDir, gamePaths, candidates };
