'use strict';
// StockPilot engine: reads the game's official mod files, records history, runs auto actions + bot,
// sends trades, and serves everything the window shows. No Electron imports (testable in plain Node).
const fs = require('fs');
const path = require('path');
const { exec } = require('child_process');
const EventEmitter = require('events');
const { num, norm, safeName, dayKey, readJson, writeJson, mkdirp, readText, exists, downsample } = require('./util');
const { findGameDir, gamePaths, APP_ID } = require('./paths');
const { HistoryStore } = require('./store');
const { Share } = require('./share');
const { Skins } = require('./skins');
const { News } = require('./news');
const { Automation, ACTIONS } = require('./automation');
const { Bot } = require('./bot');

const NWID = '__NW';
const COLOR_ORDER = ['$PLAIN', '$IDXA', '$IDXB', '$BANK', '$BUBL', '$DUMP', '$PUMP', '$QUIK', '$RIPL', '$STEP', '$STUMP', '$TECH', '$VOID', '$WAVE', '$WHALE', '$STEAM', '$IDXX'];
const PALETTE = 18;
function colorIndex(sid) { const i = COLOR_ORDER.indexOf(sid); if (i >= 0) return i; let h = 0; for (const ch of String(sid)) h = (h * 31 + ch.charCodeAt(0)) >>> 0; return h % PALETTE; }

const DEFAULT_SETTINGS = {
  theme: 'light', closeToTray: true, startWithWindows: false, openGameOnStart: false, keepAwake: false, alwaysOnTop: false,
  tradeSize: 100, confirmTrades: false, hideLocked: true, cardSort: 'game',
  share: { on: true, url: '', id: '', clockOff: 0 },
  notify: { announcements: true, events: true, auto: true, bot: true, income: false },
  window: null, migrated: false,
};
function deepMerge(base, add) {
  const out = Array.isArray(base) ? base.slice() : Object.assign({}, base);
  for (const k of Object.keys(add || {})) {
    const v = add[k];
    if (v && typeof v === 'object' && !Array.isArray(v) && base && typeof base[k] === 'object' && base[k] && !Array.isArray(base[k])) out[k] = deepMerge(base[k], v);
    else out[k] = v;
  }
  return out;
}
const posMap = m => { const p = new Map(); for (const x of (m && m.player && m.player.positions) || []) if (x) p.set(String(x.stockId), { owned: num(x.sharesOwned), shorted: num(x.sharesShorted), avgBuy: num(x.averageBuyPrice), avgShort: num(x.averageShortPrice) }); return p; };

class Engine extends EventEmitter {
  constructor(o = {}) {
    super();
    this.dataDir = mkdirp(o.dataDir);
    this.version = o.version || '2.0.0';
    this.fetch = o.fetchFn || (typeof fetch === 'function' ? fetch : null);
    this.gameDir = findGameDir(o.gameDir);
    this.p = gamePaths(this.gameDir);
    this.settingsFile = path.join(this.dataDir, 'settings.json');
    this.settings = deepMerge(DEFAULT_SETTINGS, readJson(this.settingsFile) || {});
    this.logs = []; this.logId = 0;
    const log = (m, k) => this.say(m, k);
    this.store = new HistoryStore(this.dataDir);
    this.auto = new Automation({ file: path.join(this.dataDir, 'automation.json'), log });
    this.bot = new Bot({ file: path.join(this.dataDir, 'bot.json'), log });
    this.skins = new Skins({ skinsDir: this.p.skins, dataDir: this.dataDir, log });
    this.news = new News({ fetchFn: this.fetch, log, onNew: it => this.notify('announcements', 'Screen Stocks: ' + it.title, it.text.slice(0, 180)) });
    this.share = null;
    this.market = null; this.marketStamp = ''; this.lastSeq = null; this.lastSeqAt = 0; this.readAt = 0;
    this.connected = false; this.statusMsg = 'Starting…';
    this.setup = { state: '', msg: '' }; this.nextSetup = 0; this.closedAt = null;
    this.gameRunning = false; this.backfilled = false;
    this.names = new Map(Object.entries(readJson(path.join(this.dataDir, 'names.json')) || {}));
    this.prevPos = new Map(); this.prevCash = null; this.prevIpo = null;
    this.lastCmd = new Map(); this.pending = new Map(); this.lastBuySent = 0; this.lastShortSent = 0;
    this.paused = false; this.seenResults = new Set(); this.lastResult = null; this.lastActual = null;
    this.notes = readJson(path.join(this.dataDir, 'journal-notes.json')) || {};
    this.eventNotified = new Set();
    this.netWorth = 0; this.nwEst = false;
    this.timers = [];
  }

  // ------------------------------------------------------------------ basics
  say(msg, kind = 'info') {
    const e = { id: ++this.logId, t: Date.now(), msg: String(msg), kind };
    this.logs.push(e); if (this.logs.length > 300) this.logs.shift();
    this.emit('log', e);
  }
  notify(kind, title, body) { if (this.settings.notify && this.settings.notify[kind]) this.emit('notify', { kind, title, body }); }
  saveSettings() { try { writeJson(this.settingsFile, this.settings); } catch (e) { } }

  start() {
    this.store.load();
    this.auto.load(); this.bot.load(); this.skins.animLoad();
    const sh = this.settings.share;
    if (!/^[A-Za-z0-9-]{8,64}$/.test(sh.id || '')) { sh.id = require('crypto').randomBytes(16).toString('hex'); this.saveSettings(); }
    this.share = new Share({ dataDir: this.dataDir, store: this.store, log: (m, k) => this.say(m, k), fetchFn: this.fetch, settings: sh });
    this.share.coverLoad(); this.share.loadQueue();
    this.say(`StockPilot ${this.version} started. Game folder: ${this.gameDir}`, 'info');
    this.say(`Mode: ${this.auto.dry ? 'PRACTICE' : 'LIVE'} - ${this.auto.rules.filter(r => r.enabled).length} active auto actions`, 'info');
    this.checkGame();
    const T = (fn, ms) => this.timers.push(setInterval(() => { try { fn(); } catch (e) { this.say('Error: ' + (e && e.message || e), 'err'); } }, ms));
    T(() => this.tick(), 200);
    T(() => this.store.flush(), 2000);
    T(() => { this.store.saveDaily(); this.settings.share.clockOff = this.share.off; }, 10000);
    T(() => this.checkGame(), 3000);
    T(() => this.news.refresh(), 20 * 60000);
    setTimeout(() => this.news.refresh(), 1500);
    if (this.settings.openGameOnStart) setTimeout(() => { if (this.setup.state === 'ok' && !this.gameRunning) this.launchGame(); }, 4000);
  }
  stop() {
    for (const t of this.timers) clearInterval(t); this.timers = [];
    try { this.store.flush(); this.store.saveDaily(); } catch (e) { }
    try { this.share.saveQueue(); this.share.coverSave(); } catch (e) { }
    this.settings.share.clockOff = this.share ? this.share.off : 0; this.saveSettings();
  }

  // ------------------------------------------------------------------ game
  checkGame() {
    const cmd = process.platform === 'win32' ? 'tasklist /FO CSV /NH' : 'ps -A -o comm=';
    exec(cmd, { windowsHide: true, timeout: 8000, maxBuffer: 4 * 1024 * 1024 }, (err, out) => {
      if (err) return;
      this.gameRunning = String(out).split(/\r?\n/).some(l => /screen.?stocks?|small.?short/i.test(l) && !/stockpilot|panel/i.test(l));
    });
  }
  launchGame() { this.emit('openExternal', 'steam://rungameid/' + APP_ID); this.say('Opening Screen Stocks from Steam…', 'info'); }

  setupStep() {
    if (this.setup.state === 'ok' || Date.now() < this.nextSetup) return;
    this.nextSetup = Date.now() + 2000;
    const sav = this.p.sav;
    if (!exists(sav)) { this.setup = { state: 'nosave', msg: 'Open Screen Stocks once (then close it) so it creates its settings. StockPilot finishes setup by itself.' }; return; }
    const text = readText(sav);
    if (/"modSupport"\s*:\s*"?true"?/.test(text)) { this.setup = { state: 'ok', msg: '' }; this.say('Mod support: ON', 'ok'); this.ensureModSettings(); return; }
    if (!/"modSupport"/.test(text)) { this.setup = { state: 'noopt', msg: 'Your game has no mod support option yet. Update Screen Stocks on Steam, open it once and close it.' }; return; }
    if (this.gameRunning) { this.setup = { state: 'close', msg: 'Close Screen Stocks for a moment so mod support can be switched on, then open it again.' }; this.closedAt = null; return; }
    if (this.setup.state === 'close') { if (this.closedAt === null) { this.closedAt = Date.now(); return; } if (Date.now() - this.closedAt < 2000) return; }
    const raw = fs.readFileSync(sav); const bom = raw.length >= 3 && raw[0] === 0xef && raw[1] === 0xbb && raw[2] === 0xbf;
    fs.copyFileSync(sav, sav + '.backup');
    const nw = text.replace(/("modSupport"\s*:\s*)(")?false(")?/, (m0, a, q1, q2) => a + (q1 || '') + 'true' + (q2 || ''));
    fs.writeFileSync(sav, (bom ? '﻿' : '') + nw, 'utf8');
    this.say('Mod support: switched ON (old settings saved as .backup). You can open Screen Stocks now.', 'ok');
    this.setup = { state: 'ok', msg: '' }; this.ensureModSettings();
  }
  ensureModSettings() {
    const f = this.p.modSettings, j = readJson(f);
    if (!j || this.gameRunning) return;
    const off = ['export', 'commands', 'skins'].filter(k => j[k] === false);
    if (!off.length) return;
    for (const k of off) j[k] = true;
    try { fs.writeFileSync(f, JSON.stringify(j, null, 4)); this.say(`Turned on the game's ${off.join(', ')} mod option${off.length > 1 ? 's' : ''}.`, 'ok'); } catch (e) { }
  }

  // ------------------------------------------------------------------ main loop
  tick() {
    this.setupStep();
    this.readMarket();
    if (this.share) this.share.step();
    this.skins.animStep(this.connected);
    this.checkPending();
  }
  readMarket() {
    let st = null; try { st = fs.statSync(this.p.market); } catch (e) { }
    if (!st) { this.connected = false; this.statusMsg = 'Waiting for the game - open Screen Stocks'; return; }
    const stamp = st.mtimeMs + ':' + st.size;
    if (stamp === this.marketStamp) { if (this.connected && Date.now() - this.lastSeqAt > 10000) { this.connected = false; this.statusMsg = 'Game not updating - is Screen Stocks open?'; } return; }
    let m; try { m = JSON.parse(readText(this.p.market)); } catch (e) { return; }
    this.marketStamp = stamp;
    if (!m || !m.marketReady) { this.connected = false; this.statusMsg = 'Waiting for the game - open Screen Stocks'; return; }
    const seq = String(m.sequence);
    if (seq === this.lastSeq) { if (Date.now() - this.lastSeqAt > 10000) { this.connected = false; this.statusMsg = 'Game not updating - is Screen Stocks open?'; } return; }
    const first = this.lastSeq === null;
    this.lastSeq = seq; this.lastSeqAt = Date.now(); this.readAt = Date.now(); this.market = m;
    this.onMarket(m, st.mtimeMs, first);
  }
  srvNow() { const m = this.market; return m ? num(m.serverTimeMs) + (Date.now() - this.readAt) : Date.now() + (this.share ? this.share.off : 0); }

  onMarket(m, mtime, first) {
    if (this.share) this.share.setClock(num(m.serverTimeMs), num(m.writtenAtMs) || mtime);
    let namesChanged = false;
    for (const s of m.stocks || []) { if (!s) continue; const id = String(s.stockId), nm = String(s.name || id); if (this.names.get(id) !== nm) { this.names.set(id, nm); namesChanged = true; } }
    if (namesChanged) { try { writeJson(path.join(this.dataDir, 'names.json'), Object.fromEntries(this.names)); } catch (e) { } }
    this.connected = true; this.statusMsg = 'Connected';
    if (!this.backfilled) { this.backfilled = true; try { this.backfill(); } catch (e) { this.say('Could not read the game history: ' + e.message, 'warn'); } }
    this.record(m);
    if (first) for (const r of m.commandResults || []) this.seenResults.add(JSON.stringify(r));
    this.results(m);
    this.eventNotifications(m);
    if (!this.paused) this.runCycle(m);
    this.emit('market');
  }

  record(m) {
    const t = Date.now();
    const nw = num(m.player && m.player.netWorth);
    if (nw) { this.netWorth = nw; this.nwEst = false; } else { this.netWorth = this.computeNetWorth(m); this.nwEst = true; }
    const points = [];
    for (const s of m.stocks || []) if (s && s.unlocked !== false) points.push([String(s.stockId), num(s.price)]);
    this.store.addPrices(t, points.concat([[NWID, this.netWorth]]));
    this.detectTrades(m, t);
    this.store.updateDaily(this.netWorth);
    const srvT = num(m.serverTimeMs);
    if (srvT > 0 && this.share) { if (this.share.active()) for (const [sid, p] of points) this.share.addOne(srvT, sid, p); this.share.coverExtend(srvT); }
  }
  computeNetWorth(m) {
    const px = new Map((m.stocks || []).map(s => [String(s.stockId), num(s.price)]));
    let nw = num(m.player && m.player.cash);
    for (const [sid, p] of posMap(m)) { const x = px.get(sid) || 0; nw += p.owned * x; if (p.shorted > 0) { const a = p.avgShort > 0 ? p.avgShort : x; nw += p.shorted * (2 * a - x); } }
    return nw;
  }
  detectTrades(m, t) {
    const pos = posMap(m); let soldOrShort = false;
    for (const s of m.stocks || []) {
      if (!s) continue;
      const sid = String(s.stockId), p = pos.get(sid) || { owned: 0, shorted: 0 }, prev = this.prevPos.get(sid);
      this.prevPos.set(sid, [p.owned, p.shorted]);
      if (!prev) continue;
      const px = num(s.price), lc = this.lastCmd.get(sid), src = lc && t - lc.at < 8000 ? lc.src : 'you';
      const add = (action, qty) => {
        this.store.addTrade(t, sid, action, qty, px, src);
        this.pending.delete(sid);
        this.lastActual = { t, text: `${action.toUpperCase()} ${s.name || sid} · completed`, src };
        this.say(`Trade: ${action.toUpperCase()} ${fmtShort(qty)} ${s.name || sid} @ ${fmtP(px)} (${srcName(src)})`, src === 'you' ? 'info' : 'ok');
        if (src === 'auto' || src === 'bot') this.notify(src, `${srcName(src)}: ${action.toUpperCase()} ${s.name || sid}`, `${fmtShort(qty)} shares @ ${fmtP(px)}`);
      };
      if (p.owned > prev[0] + 1e-9) add('buy', p.owned - prev[0]); else if (p.owned < prev[0] - 1e-9) { add('sell', prev[0] - p.owned); soldOrShort = true; }
      if (p.shorted > prev[1] + 1e-9) { add('short', p.shorted - prev[1]); soldOrShort = true; } else if (p.shorted < prev[1] - 1e-9) add('cover', prev[1] - p.shorted);
    }
    // cash that comes in without a sale/short = dividends (or other income)
    const cash = num(m.player && m.player.cash), ipo = m.player ? m.player.ipoCount : null;
    if (this.prevCash !== null && cash > this.prevCash && !soldOrShort && ipo === this.prevIpo) {
      const inc = cash - this.prevCash;
      this.store.addIncome(t, inc);
      this.notify('income', 'Dividends', '+' + fmtShort(inc));
    }
    this.prevCash = cash; this.prevIpo = ipo;
  }
  results(m) {
    for (const r of m.commandResults || []) {
      const k = JSON.stringify(r); if (this.seenResults.has(k)) continue;
      this.seenResults.add(k); if (this.seenResults.size > 2000) this.seenResults = new Set([...this.seenResults].slice(-1000));
      const text = describeResult(r, this.names);
      this.lastResult = { t: Date.now(), text };
      this.say('Game: ' + text, /fail|error|reject|denied|not enough|cooldown/i.test(text) ? 'warn' : 'info');
    }
  }
  eventNotifications(m) {
    const now = this.srvNow();
    for (const ev of m.scheduledNews || []) {
      const left = num(ev.scheduledAtMs) - now;
      if (left > 0 && left <= 5 * 60000 && !this.eventNotified.has(ev.occurrenceId)) {
        this.eventNotified.add(ev.occurrenceId);
        const nm = this.names.get(String(ev.stockId)) || ev.stockId;
        this.notify('events', `${nm}: ${ev.direction} to ${ev.targetPrice} soon`, `Scheduled in ${Math.round(left / 60000)} min`);
      }
    }
  }
  backfill() {
    const h = readJson(this.p.history); if (!h || !Array.isArray(h.stocks)) return;
    const off = this.share ? this.share.off : 0; let added = 0;
    for (const st of h.stocks) {
      const sid = String(st.stockId); if (!Array.isArray(st.samples) || !st.samples.length) continue;
      const srv = st.samples.map(x => [num(x.timeMs), num(x.price)]).filter(x => x[0] > 0);
      if (!srv.length) continue;
      if (this.share && this.share.active()) for (const pt of srv) this.share.addOne(pt[0], sid, pt[1]);
      if (this.share) this.share.coverAdd(srv[0][0], srv[srv.length - 1][0] + 1000);
      const loc = srv.map(x => [x[0] - off, x[1]]);
      this.store.insertLive(sid, loc);
      const key = safeName(sid), lw = this.store.lastW.get(key), last = lw ? lw[0] : 0;
      const byDay = new Map();
      for (const pt of loc) {
        if (pt[0] <= last) continue;
        const dk = dayKey(pt[0]); byDay.set(dk, (byDay.get(dk) || '') + Math.round(pt[0]) + ',' + pt[1] + '\n');
        if (dk === this.store.dk) { let mem = this.store.dayMem.get(key); if (!mem) { mem = []; this.store.dayMem.set(key, mem); } mem.push([Math.round(pt[0]), pt[1]]); }
        added++;
      }
      for (const [dk, text] of byDay) this.store.appendDayLines(dk, key + '.csv', text);
      const mem = this.store.dayMem.get(key); if (mem) mem.sort((a, b) => a[0] - b[0]);
      if (loc.length) this.store.lastW.set(key, loc[loc.length - 1]);
    }
    if (added) this.say(`Filled in ${added} earlier price points from the game's own history.`, 'info');
  }

  // ------------------------------------------------------------------ trading
  cooldowns() {
    const m = this.market; if (!m || !m.player) return { buy: 0, short: 0, buyTotal: 0, shortTotal: 0 };
    const now = this.srvNow();
    return { buy: Math.max(0, (num(m.player.nextBuyAtMs) - now) / 1000), short: Math.max(0, (num(m.player.nextShortAtMs) - now) / 1000), buyTotal: num(m.player.buyCooldownSeconds), shortTotal: num(m.player.shortCooldownSeconds) };
  }
  can(action, sid, pos, why) {
    const p = pos.get(sid) || { owned: 0, shorted: 0 }, c = this.cooldowns(), now = Date.now();
    const no = r => { if (why) why.reason = r; return false; };
    if (this.pending.has(sid) && now - this.pending.get(sid).at < 15000) return no('An order for this stock is still waiting for the game.');
    if (action === 'buy') { if (now - this.lastBuySent < 2000) return no('Just bought - wait a moment.'); if (c.buy > 0) return no(`Buy cooldown: ${Math.ceil(c.buy)}s`); }
    if (action === 'short') { if (now - this.lastShortSent < 2000) return no('Just shorted - wait a moment.'); if (c.short > 0) return no(`Short cooldown: ${Math.ceil(c.short)}s`); }
    if (action === 'sell' && !(p.owned > 0)) return no('You own none of this stock.');
    if (action === 'cover' && !(p.shorted > 0)) return no('You have no short on this stock.');
    if (action === 'close' && !(p.owned > 0) && !(p.shorted > 0)) return no('Nothing to close on this stock.');
    return true;
  }
  send(sid, action, pct, src, dry, why) {
    if (dry) { this.say('[PRACTICE] would ' + why, 'info'); return true; }
    const dir = path.join(this.p.commands, sid);
    if (!exists(dir)) { this.say(`No command folder for ${sid} yet - open the game with mod support on.`, 'err'); return false; }
    const max = pct >= 100, file = path.join(dir, action + (max ? 'max.json' : 'percent.json'));
    const cur = readJson(file); if (cur && cur.execute === true) return false;
    try { fs.writeFileSync(file, max ? '{\n  "execute": true\n}' : '{\n  "execute": true,\n  "percent": ' + Math.round(pct) + '\n}'); }
    catch (e) { this.say('Could not write the order: ' + e.message, 'err'); return false; }
    this.lastCmd.set(sid, { at: Date.now(), src, action });
    this.pending.set(sid, { action, file, at: Date.now(), src, warned: false });
    if (action === 'buy') this.lastBuySent = Date.now();
    if (action === 'short') this.lastShortSent = Date.now();
    this.say('[SENT] ' + why, 'ok');
    return true;
  }
  checkPending() {
    const now = Date.now();
    for (const [sid, p] of this.pending) {
      const cur = readJson(p.file, 1);
      if (cur && cur.execute === false && now - p.at > 400) { this.pending.delete(sid); continue; }
      if (!p.warned && now - p.at > 30000) { p.warned = true; this.say(`The game hasn't picked up the ${p.action} order for ${this.names.get(sid) || sid} yet - is Screen Stocks open?`, 'warn'); }
      if (now - p.at > 120000) this.pending.delete(sid);
    }
  }
  runCycle(m) {
    const stocks = new Map(), lookup = new Map();
    for (const s of m.stocks || []) { if (!s) continue; const id = String(s.stockId); stocks.set(id, s); lookup.set(norm(id), id); if (s.name) lookup.set(norm(s.name), id); }
    const pos = posMap(m);
    const ctx = { stocks, lookup, pos, can: (a, sid) => this.can(a, sid, pos), send: (sid, a, pct, src, dry, why) => this.send(sid, a, pct, src, dry, why) };
    this.auto.cycle(ctx);
    this.bot.cycle(Object.assign({}, ctx, { now: this.srvNow(), scheduled: m.scheduledNews || [], avg: (sid, ms) => this.avg(sid, ms) }));
  }
  avg(sid, ms) {
    const l = this.store.live.get(sid); if (!l || l.t.length < 5) return null;
    const now = l.t[l.t.length - 1], from = now - ms;
    if (l.t[0] > from + ms * 0.5) return null;
    let s = 0, n = 0; for (let i = l.t.length - 1; i >= 0 && l.t[i] >= from; i--) { s += l.p[i]; n++; }
    return n ? s / n : null;
  }

  // ------------------------------------------------------------------ API for the window
  state() {
    const m = this.market, pos = posMap(m), stocks = [];
    for (const s of (m && m.stocks) || []) {
      if (!s) continue;
      const id = String(s.stockId), price = num(s.price), p = pos.get(id) || { owned: 0, shorted: 0, avgBuy: 0, avgShort: 0 };
      const hl = this.store.hiLo(id, 300000) || { hi: price, lo: price };
      stocks.push({
        id, name: String(s.name || id), ci: colorIndex(id), price, unlocked: s.unlocked !== false,
        base: num(s.basePrice), cap: num(s.priceCap), div: num(s.dividendRate), avail: num(s.availableShares), maxVol: num(s.maxVolume),
        owned: p.owned, avgBuy: p.avgBuy, shorted: p.shorted, avgShort: p.avgShort,
        plL: p.owned > 0 ? p.owned * (price - p.avgBuy) : 0, plLPct: p.owned > 0 && p.avgBuy > 0 ? (price - p.avgBuy) / p.avgBuy * 100 : null,
        plS: p.shorted > 0 ? p.shorted * (p.avgShort - price) : 0, plSPct: p.shorted > 0 && p.avgShort > 0 ? (p.avgShort - price) / p.avgShort * 100 : null,
        c10s: this.store.change(id, 10000), c1m: this.store.change(id, 60000), c5m: this.store.change(id, 300000), c1h: this.store.change(id, 3600000),
        hi: hl.hi, lo: hl.lo, spark: this.store.spark(id, 300000, 90),
        pending: this.pending.has(id) ? this.pending.get(id).action : null,
      });
    }
    const d = this.store.daily[this.store.dk], cool = this.cooldowns();
    const names = id => this.names.get(String(id)) || String(id);
    return {
      v: this.version, connected: this.connected, status: this.statusMsg, setup: this.setup, paused: this.paused,
      gameVersion: m ? m.gameVersion : '', level: m && m.player ? m.player.level : null, ipoCount: m && m.player ? m.player.ipoCount : null,
      cash: m && m.player ? num(m.player.cash) : null, netWorth: this.netWorth || null, nwEst: this.nwEst,
      nwChg1h: this.store.change(NWID, 3600000),
      today: d ? { start: d.start, profit: d.last - d.start, pct: d.start ? (d.last - d.start) / Math.abs(d.start) * 100 : null } : null,
      cool, srvNow: this.srvNow(), stocks,
      news: {
        market: ((m && m.marketNews) || []).slice(-60).reverse().map(n => ({ id: n.id, t: num(n.createdAtMs), sid: n.stockId, name: names(n.stockId), ci: colorIndex(String(n.stockId)), price: num(n.price), kind: n.kind, look: num(n.lookbackMinutes) })),
        scheduled: ((m && m.scheduledNews) || []).map(n => ({ id: n.occurrenceId, sid: n.stockId, name: names(n.stockId), ci: colorIndex(String(n.stockId)), dir: n.direction, target: num(n.targetPrice), at: num(n.scheduledAtMs), pub: num(n.publishedAtMs) })).sort((a, b) => a.at - b.at),
        steamCount: this.news.items.length, steamLatest: this.news.items[0] ? this.news.items[0].id : '',
      },
      auto: { dry: this.auto.dry, rules: this.auto.rules, status: this.auto.status(), version: this.auto.version, error: this.auto.error },
      bot: this.bot.status(),
      trades: this.store.trades.slice(-60).map(x => ({ t: x[0], sid: x[1], name: names(x[1]), ci: colorIndex(x[1]), action: x[2], qty: x[3], price: x[4], src: x[5] })),
      log: this.logs.slice(-80),
      lastActual: this.lastActual, lastResult: this.lastResult, pendingCount: this.pending.size,
      share: { on: this.share ? this.share.on : false, msg: this.share ? this.share.message() : '', url: this.settings.share.url || '' },
      settings: this.settings, gameDir: this.gameDir, dataDir: this.dataDir, gameRunning: this.gameRunning,
    };
  }
  history(sid, range) {
    const h = this.store.history(sid, range);
    const p = posMap(this.market).get(sid) || {};
    h.avgBuy = p.avgBuy || 0; h.avgShort = p.avgShort || 0; h.owned = p.owned || 0; h.shorted = p.shorted || 0;
    h.trades = h.trades.map(x => [x[0], x[2], x[3], x[4], x[5]]);
    return h;
  }
  compare(ids, range) {
    const out = {};
    for (const id of (ids || []).slice(0, 17)) { const h = this.store.history(String(id), range, 700); out[id] = h.points; }
    return { range, series: out };
  }
  trade(sid, action, pct) {
    sid = String(sid); action = String(action).toLowerCase(); pct = Math.round(Math.max(1, Math.min(100, num(pct) || 100)));
    if (!ACTIONS.includes(action)) return { ok: false, error: 'Unknown action.' };
    const m = this.market; if (!m || !this.connected) return { ok: false, error: 'Open Screen Stocks first.' };
    const s = (m.stocks || []).find(x => String(x.stockId) === sid); if (!s) return { ok: false, error: 'Stock not found.' };
    if (s.unlocked === false) return { ok: false, error: 'That stock is still locked in the game.' };
    const why = {}; if (!this.can(action, sid, posMap(m), why)) return { ok: false, error: why.reason || 'Not possible right now.' };
    const ok = this.send(sid, action, pct, 'app', false, `${action.toUpperCase()} ${s.name || sid} ${pct >= 100 ? 'MAX' : pct + '%'}`);
    return ok ? { ok: true } : { ok: false, error: 'The previous order is still waiting for the game.' };
  }
  setAuto(dry, rules) { this.auto.setDoc(!!dry, rules || []); return { ok: true, version: this.auto.version }; }
  setPaused(b) { this.paused = !!b; this.say(this.paused ? 'Paused - no auto trades until you resume.' : 'Resumed.', this.paused ? 'warn' : 'ok'); return this.paused; }
  setSettings(patch) {
    this.settings = deepMerge(this.settings, patch || {});
    if (this.share && patch && patch.share) {
      if (patch.share.on !== undefined) { this.share.on = !!patch.share.on; this.share.err = ''; }
      if (patch.share.url !== undefined) { const u = String(patch.share.url).trim().replace(/\/+$/, ''); if (u === '' || /^https?:\/\/[A-Za-z0-9.\-:]+$/.test(u)) { this.share.url = u; this.settings.share.url = u; this.share.err = ''; this.share.nextUp = this.share.nextFill = this.share.nextStatus = Date.now(); } }
    }
    this.saveSettings(); this.emit('settings', this.settings);
    return this.settings;
  }
  botSet(p) { this.bot.set(p || {}); return this.bot.status(); }
  newsList() { return { items: this.news.items, err: this.news.err, fetchedAt: this.news.fetchedAt }; }
  async refreshNews() { await this.news.refresh(); return this.newsList(); }
  journal() {
    const names = id => this.names.get(String(id)) || String(id);
    const trades = this.store.allTrades(0).map(x => ({ t: x[0], sid: x[1], name: names(x[1]), ci: colorIndex(x[1]), action: x[2], qty: x[3], price: x[4], src: x[5] })).sort((a, b) => b.t - a.t);
    return { trades, notes: this.notes };
  }
  setNote(day, text) {
    if (!/^\d{4}-\d\d-\d\d$/.test(day)) return false;
    if (text && String(text).trim()) this.notes[day] = String(text).slice(0, 20000); else delete this.notes[day];
    try { writeJson(path.join(this.dataDir, 'journal-notes.json'), this.notes); } catch (e) { }
    return true;
  }
  stats() {
    const daily = Object.keys(this.store.daily).sort().map(k => { const v = this.store.daily[k]; return { date: k, start: v.start, last: v.last, high: v.high, low: v.low, profit: v.last - v.start }; });
    const trades = this.store.allTrades(0).sort((a, b) => a[0] - b[0]);
    const lots = new Map(), shorts = new Map(); let realized = 0, wins = 0, closes = 0;
    const perStock = {}, bySrc = {};
    for (const [t, sid, action, qty, price, src] of trades) {
      perStock[sid] = perStock[sid] || { n: 0, realized: 0 }; perStock[sid].n++;
      bySrc[src] = (bySrc[src] || 0) + 1;
      if (action === 'buy') { (lots.get(sid) || lots.set(sid, []).get(sid)).push([qty, price]); }
      else if (action === 'short') { (shorts.get(sid) || shorts.set(sid, []).get(sid)).push([qty, price]); }
      else if (action === 'sell' || action === 'cover') {
        const q0 = action === 'sell' ? lots.get(sid) : shorts.get(sid); let q = qty, r = 0;
        while (q > 1e-9 && q0 && q0.length) { const lot = q0[0], take = Math.min(q, lot[0]); r += action === 'sell' ? take * (price - lot[1]) : take * (lot[1] - price); lot[0] -= take; q -= take; if (lot[0] <= 1e-9) q0.shift(); }
        if (q < qty) { realized += r; perStock[sid].realized += r; closes++; if (r > 0) wins++; }
      }
    }
    const inc = this.store.income, now = Date.now();
    const gaps = []; for (let i = 1; i < inc.length; i++) gaps.push(inc[i][0] - inc[i - 1][0]);
    gaps.sort((a, b) => a - b);
    const names = id => this.names.get(String(id)) || String(id);
    return {
      daily, realized, wins, closes, winRate: closes ? wins / closes * 100 : null, tradeCount: trades.length,
      perStock: Object.entries(perStock).map(([sid, v]) => ({ sid, name: names(sid), ci: colorIndex(sid), n: v.n, realized: v.realized })).sort((a, b) => b.n - a.n),
      bySrc,
      income: { total: inc.reduce((s, x) => s + x[1], 0), day: inc.filter(x => now - x[0] < 86400000).reduce((s, x) => s + x[1], 0), count: inc.length, interval: gaps.length ? gaps[Math.floor(gaps.length / 2)] : null, recent: inc.slice(-40).reverse() },
      nwSeries: this.store.history(NWID, '7d', 600).points,
    };
  }
}

function fmtShort(n) {
  if (n == null || isNaN(n)) return '-'; const a = Math.abs(n);
  for (const [v, s] of [[1e27, 'Oc'], [1e24, 'Sp'], [1e21, 'Sx'], [1e18, 'Qi'], [1e15, 'Qa'], [1e12, 'T'], [1e9, 'B'], [1e6, 'M'], [1e3, 'K']]) if (a >= v) { const x = n / v; return (Math.abs(x) >= 100 ? x.toFixed(0) : Math.abs(x) >= 10 ? x.toFixed(1) : x.toFixed(2)) + s; }
  return a < 1000 ? String(+n.toFixed(2)) : n.toFixed(0);
}
function fmtP(n) { const a = Math.abs(n); return a >= 1e5 ? fmtShort(n) : a >= 1000 ? n.toFixed(1) : n.toFixed(3); }
function srcName(s) { return { you: 'you in the game', app: 'you in StockPilot', auto: 'auto action', bot: 'bot' }[s] || s; }
function describeResult(r, names) {
  if (!r || typeof r !== 'object') return String(r);
  const sid = r.stockId || r.stock || r.symbol || '';
  const nm = sid ? (names.get(String(sid)) || sid) : '';
  const act = r.command || r.action || r.type || r.kind || '';
  const st = r.status || r.result || (r.success === true ? 'completed' : r.success === false ? 'failed' : '');
  const msg = r.message || r.error || r.reason || '';
  const txt = [String(act).toUpperCase(), nm].filter(Boolean).join(' ') + (st ? ' · ' + st : '') + (msg ? ' - ' + msg : '');
  return txt.trim() || JSON.stringify(r).slice(0, 160);
}

module.exports = { Engine, DEFAULT_SETTINGS, colorIndex, NWID, fmtShort };
