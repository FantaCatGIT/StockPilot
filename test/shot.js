'use strict';
// Test-only: start the real app, then run UI steps and save screenshots. electron test/shot.js <outDir> <steps.json>
const { app, BrowserWindow } = require('electron');
const fs = require('fs'), path = require('path');
const [outDir, stepsFile] = process.argv.slice(-2);
require('../main.js');
const wait = ms => new Promise(r => setTimeout(r, ms));
app.whenReady().then(async () => {
  await wait(5000);
  const w = BrowserWindow.getAllWindows()[0];
  w.setSize(1440, 920);
  w.webContents.on('console-message', (e, lvl, msg) => { if (lvl >= 2) console.log('[console]', msg); });
  for (const [name, js, ms] of JSON.parse(fs.readFileSync(stepsFile, 'utf8'))) {
    if (js) { try { const r = await w.webContents.executeJavaScript(js); if (r !== undefined) console.log(name, '=>', JSON.stringify(r)); } catch (e) { console.log(name, 'JS error', e.message); } }
    await wait(ms || 1500);
    if (name[0] !== '_') { const img = await w.webContents.capturePage(); fs.writeFileSync(path.join(outDir, name + '.png'), img.toPNG()); }
  }
  app.exit(0);
});
