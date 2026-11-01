'use strict';
// Test-only Screen Stocks simulator: keeps writing mods/export/market.json like the game (1/s)
// and executes mods/commands/<id>/*.json orders. Usage: node test/sim.js <gameDir> <template market.json>
const fs = require('fs');
const path = require('path');
const [gameDir, tpl] = process.argv.slice(2);
const m = JSON.parse(fs.readFileSync(tpl, 'utf8'));
const mods = path.join(gameDir, 'mods'), cmds = path.join(mods, 'commands');
fs.mkdirSync(path.join(mods, 'export'), { recursive: true });
for (const s of m.stocks) {
  const d = path.join(cmds, s.stockId); fs.mkdirSync(d, { recursive: true });
  for (const a of ['buy', 'sell', 'short', 'cover', 'close']) {
    if (!fs.existsSync(path.join(d, a + 'max.json'))) fs.writeFileSync(path.join(d, a + 'max.json'), '{\n  "execute": false\n}');
    if (!fs.existsSync(path.join(d, a + 'percent.json'))) fs.writeFileSync(path.join(d, a + 'percent.json'), '{\n  "execute": false,\n  "percent": 25\n}');
  }
}
if (!fs.existsSync(path.join(gameDir, 'thesmallshort_online_settings.sav'))) fs.writeFileSync(path.join(gameDir, 'thesmallshort_online_settings.sav'), '{"modSupport":true,"volume":0.5}');
let cash = parseFloat(m.player.cash), seq = m.sequence;
const pos = new Map(m.player.positions.map(p => [p.stockId, { o: +p.sharesOwned, ab: +p.averageBuyPrice, s: +p.sharesShorted, as: +p.averageShortPrice }]));
const now0 = Date.now(), srvOff = m.serverTimeMs - m.writtenAtMs;
// make the scheduled events land a few minutes from now so countdowns look alive
m.scheduledNews.forEach((e, i) => { e.scheduledAtMs = Date.now() + srvOff + (3 + i * 7) * 60000; });
m.commandResults = [];
function tick() {
  seq++;
  const t = Date.now();
  for (const s of m.stocks) {
    const r = (Math.random() - 0.5) * 0.04 * (s.stockId === '$PLAIN' ? 0.3 : 1);
    s.price = Math.max(1, Math.min(s.priceCap || 1e6, s.price * (1 + r)));
  }
  if (Math.random() < 0.08) { const s = m.stocks[Math.floor(Math.random() * m.stocks.length)]; m.marketNews.push({ id: 'n' + t, createdAtMs: t + srvOff, stockId: s.stockId, price: s.price, kind: Math.random() < 0.5 ? 'high' : 'low', lookbackMinutes: 5 }); if (m.marketNews.length > 50) m.marketNews.shift(); }
  // execute orders
  for (const s of m.stocks) {
    const d = path.join(cmds, s.stockId); let files; try { files = fs.readdirSync(d); } catch (e) { continue; }
    for (const f of files) {
      let j; try { j = JSON.parse(fs.readFileSync(path.join(d, f), 'utf8')); } catch (e) { continue; }
      if (!j.execute) continue;
      const a = f.replace(/(max|percent)\.json$/, ''), pct = f.includes('percent') ? (j.percent || 25) / 100 : 1;
      const p = pos.get(s.stockId) || { o: 0, ab: 0, s: 0, as: 0 };
      let status = 'completed';
      if (a === 'buy') { const spend = cash * pct, q = spend / s.price; if (q > 0) { p.ab = (p.o * p.ab + q * s.price) / (p.o + q); p.o += q; cash -= spend; m.player.nextBuyAtMs = t + srvOff + m.player.buyCooldownSeconds * 1000; } else status = 'failed'; }
      else if (a === 'sell') { const q = p.o * pct; if (q > 0) { p.o -= q; cash += q * s.price; } else status = 'failed'; }
      else if (a === 'short') { const q = cash * pct / s.price; p.as = (p.s * p.as + q * s.price) / (p.s + q || 1); p.s += q; cash += q * s.price; m.player.nextShortAtMs = t + srvOff + m.player.shortCooldownSeconds * 1000; }
      else if (a === 'cover') { const q = p.s * pct; p.s -= q; cash -= q * s.price; }
      else if (a === 'close') { cash += p.o * s.price - p.s * s.price; p.o = 0; p.s = 0; }
      pos.set(s.stockId, p);
      j.execute = false; fs.writeFileSync(path.join(d, f), JSON.stringify(j, null, 2));
      m.commandResults.push({ stockId: s.stockId, command: a, status }); if (m.commandResults.length > 10) m.commandResults.shift();
    }
  }
  if (Math.random() < 0.05) cash += 1e15; // dividend
  m.player.positions = [...pos].filter(([, p]) => p.o > 1e-6 || p.s > 1e-6).map(([id, p]) => ({ stockId: id, sharesOwned: String(p.o), averageBuyPrice: p.ab, sharesShorted: String(p.s), averageShortPrice: p.as }));
  m.player.cash = String(cash);
  let nw = cash; for (const [id, p] of pos) { const s = m.stocks.find(x => x.stockId === id); nw += p.o * s.price + p.s * (2 * p.as - s.price); }
  m.player.netWorth = String(nw);
  m.sequence = seq; m.writtenAtMs = t; m.serverTimeMs = t + srvOff; m.lastPriceUpdateAtMs = t;
  const out = path.join(mods, 'export', 'market.json');
  fs.writeFileSync(out + '.tmp', JSON.stringify(m)); fs.renameSync(out + '.tmp', out);
}
tick(); setInterval(tick, 1000);
console.log('sim running', gameDir, 'since', now0);
