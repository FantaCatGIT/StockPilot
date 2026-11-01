'use strict';
// price history, trades and daily net worth on disk (same layout as StockPilot 1.x so old data keeps working):
//   history/<YYYY-MM-DD>/<stock>.csv        "timeMs,price" lines you recorded
//   history/<YYYY-MM-DD>/<stock>.shared.csv  prices other players shared (fills gaps)
//   history/<YYYY-MM-DD>/trades.csv         "timeMs,stockId,action,qty,price,source"
//   daily.json                              net worth per day {start,last,high,low}
const fs = require('fs');
const path = require('path');
const { safeName, dayKey, readJson, writeJson, mkdirp, lastAtOrBefore, downsample } = require('./util');

const LIVE_MS = 3 * 3600 * 1000;
const SPANS = { '1m': 60, '5m': 300, '15m': 900, '1h': 3600, '3h': 10800, '6h': 21600, '24h': 86400, '7d': 604800 };

function parseSeries(text, gap, out) {
  let lastKept = -Infinity, lastPt = null;
  const lines = text.split('\n');
  for (const line of lines) {
    const i = line.indexOf(','); if (i < 1) continue;
    const t = +line.slice(0, i), p = +line.slice(i + 1);
    if (!isFinite(t) || !isFinite(p)) continue;
    lastPt = [t, p];
    if (gap <= 0 || t - lastKept >= gap) { out.push(lastPt); lastKept = t; }
  }
  if (lastPt && out.length && out[out.length - 1][0] < lastPt[0]) out.push(lastPt);
  return out;
}

class HistoryStore {
  constructor(dataDir) {
    this.dataDir = dataDir;
    this.histDir = mkdirp(path.join(dataDir, 'history'));
    this.live = new Map();      // stockId -> {t:[], p:[]}
    this.dayMem = new Map();    // safe key -> [[t,p]] today, >= 5s apart
    this.lastW = new Map();     // safe key -> [t,p] last line written
    this.writeBuf = new Map();  // safe key -> string
    this.dayCache = new Map();  // "day|stockId" -> series
    this.tradeCache = new Map();// day -> trades
    this.trades = [];           // today: [t, stockId, action, qty, price, src]
    this.daily = {};
    this.income = [];           // [[t, amount]] cash that came in without a trade (dividends)
    this.dk = dayKey();
  }

  load() {
    const d = readJson(path.join(this.dataDir, 'daily.json'));
    if (d) for (const k of Object.keys(d)) { const v = d[k]; this.daily[k] = { start: +v.start || 0, last: +v.last || 0, high: +v.high || 0, low: +v.low || 0 }; }
    const inc = readJson(path.join(this.dataDir, 'income.json'));
    if (Array.isArray(inc)) this.income = inc.filter(x => Array.isArray(x) && x.length >= 2);
    this.dk = dayKey();
    const dir = path.join(this.histDir, this.dk);
    if (fs.existsSync(dir)) {
      for (const f of fs.readdirSync(dir)) {
        if (!f.endsWith('.csv')) continue;
        if (f === 'trades.csv') { this.trades = this.readTrades(path.join(dir, f)); continue; }
        const key = f.replace(/\.shared\.csv$|\.csv$/, '');
        if (this.dayMem.has(key)) continue;
        const ser = this.readDay(this.dk, key, 5000);
        this.dayMem.set(key, ser);
        if (ser.length) this.lastW.set(key, ser[ser.length - 1]);
      }
    }
  }

  readTrades(file) {
    const out = [];
    try {
      for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
        const a = line.split(','); if (a.length < 6) continue;
        const t = +a[0], q = +a[3], p = +a[4];
        if (isFinite(t) && isFinite(q) && isFinite(p)) out.push([t, a[1], a[2], q, p, a[5].trim()]);
      }
    } catch (e) { }
    return out;
  }

  readDay(dk, key, gap = 0) {
    const dir = path.join(this.histDir, dk);
    const out = [];
    let files = 0;
    for (const f of [key + '.csv', key + '.shared.csv']) {
      const p = path.join(dir, f);
      try { if (fs.existsSync(p)) { parseSeries(fs.readFileSync(p, 'utf8'), 0, out); files++; } } catch (e) { }
    }
    if (files > 1) out.sort((a, b) => a[0] - b[0]);
    if (gap <= 0) return out;
    const thin = []; let lastKept = -Infinity;
    for (const pt of out) if (pt[0] - lastKept >= gap) { thin.push(pt); lastKept = pt[0]; }
    if (out.length && thin[thin.length - 1] !== out[out.length - 1]) thin.push(out[out.length - 1]);
    return thin;
  }

  rollDay() {
    const k = dayKey();
    if (k === this.dk) return false;
    this.flush();
    this.dk = k; this.dayMem = new Map(); this.trades = [];
    return true;
  }

  // one market update: [[stockId, price], ...]
  addPrices(t, points) {
    this.rollDay();
    const cut = t - LIVE_MS;
    for (const [sid, p] of points) {
      let l = this.live.get(sid); if (!l) { l = { t: [], p: [] }; this.live.set(sid, l); }
      if (l.t.length && t <= l.t[l.t.length - 1]) continue;
      l.t.push(t); l.p.push(p);
      if (l.t.length > 1000 && l.t[0] < cut - 600000) { const drop = lastAtOrBefore(l.t, cut) + 1; if (drop > 0) { l.t.splice(0, drop); l.p.splice(0, drop); } }
      // history file: every change, unchanged prices at most once per 10 s
      const key = safeName(sid); const lw = this.lastW.get(key);
      if (lw && lw[1] === p && t - lw[0] < 10000) continue;
      this.lastW.set(key, [t, p]);
      this.writeBuf.set(key, (this.writeBuf.get(key) || '') + t + ',' + p + '\n');
      let mem = this.dayMem.get(key); if (!mem) { mem = []; this.dayMem.set(key, mem); }
      if (!mem.length || t - mem[mem.length - 1][0] >= 5000) mem.push([t, p]);
    }
  }

  // older points (game's history.json backfill or shared prices) into the live buffer
  insertLive(sid, pts) {
    let l = this.live.get(sid); if (!l) { l = { t: [], p: [] }; this.live.set(sid, l); }
    const merged = [];
    let i = 0, j = 0;
    const a = pts.slice().sort((x, y) => x[0] - y[0]);
    while (i < a.length || j < l.t.length) {
      if (j >= l.t.length || (i < a.length && a[i][0] < l.t[j])) { merged.push(a[i]); i++; }
      else { merged.push([l.t[j], l.p[j]]); j++; }
    }
    const cut = Date.now() - LIVE_MS; const t = [], p = [];
    let last = -Infinity;
    for (const pt of merged) { if (pt[0] < cut || pt[0] - last < 500) continue; t.push(pt[0]); p.push(pt[1]); last = pt[0]; }
    l.t = t; l.p = p;
  }

  appendDayLines(dk, file, text) {
    const dir = mkdirp(path.join(this.histDir, dk));
    try { fs.appendFileSync(path.join(dir, file), text); } catch (e) { }
    for (const k of [...this.dayCache.keys()]) if (k.startsWith(dk + '|')) this.dayCache.delete(k);
  }

  addTrade(t, sid, action, qty, price, src) {
    this.trades.push([t, sid, action, qty, price, src]);
    this.appendDayLines(dayKey(t), 'trades.csv', t + ',' + sid + ',' + action + ',' + qty + ',' + price + ',' + src + '\n');
    this.tradeCache.delete(dayKey(t));
  }

  addIncome(t, amount) {
    this.income.push([t, amount]);
    if (this.income.length > 3000) this.income.splice(0, this.income.length - 3000);
    this.incomeDirty = true;
  }

  updateDaily(nw) {
    if (!(nw > 0 || nw < 0)) return;
    let d = this.daily[this.dk];
    if (!d) { d = { start: nw, last: nw, high: nw, low: nw }; this.daily[this.dk] = d; }
    d.last = nw; if (nw > d.high) d.high = nw; if (nw < d.low) d.low = nw;
  }

  flush() {
    if (!this.writeBuf.size) return;
    const dir = mkdirp(path.join(this.histDir, this.dk));
    for (const [k, s] of this.writeBuf) { if (!s) continue; try { fs.appendFileSync(path.join(dir, k + '.csv'), s); } catch (e) { } }
    this.writeBuf.clear();
  }

  saveDaily() {
    const o = {}; for (const k of Object.keys(this.daily).sort()) o[k] = this.daily[k];
    try { writeJson(path.join(this.dataDir, 'daily.json'), o); } catch (e) { }
    if (this.incomeDirty) { try { writeJson(path.join(this.dataDir, 'income.json'), this.income); this.incomeDirty = false; } catch (e) { } }
  }

  // % change of the price over the last `ms` (null when not enough data yet)
  change(sid, ms) {
    const l = this.live.get(sid); if (!l || l.t.length < 2) return null;
    const now = l.t[l.t.length - 1], i = lastAtOrBefore(l.t, now - ms);
    if (i < 0) return null;
    // the reference price must really be from ~ms ago (not from before a gap while the game was closed)
    if ((now - ms) - l.t[i] > Math.max(15000, ms * 0.5)) return null;
    const a = l.p[i], b = l.p[l.p.length - 1];
    return a ? (b - a) / a * 100 : null;
  }

  liveRange(sid, from) {
    const l = this.live.get(sid); if (!l) return [];
    const i = Math.max(0, lastAtOrBefore(l.t, from) + 1);
    const out = []; for (let k = i; k < l.t.length; k++) out.push([l.t[k], l.p[k]]);
    return out;
  }

  hiLo(sid, ms) {
    const l = this.live.get(sid); if (!l || !l.t.length) return null;
    const i = Math.min(l.t.length - 1, lastAtOrBefore(l.t, l.t[l.t.length - 1] - ms) + 1);
    let hi = -Infinity, lo = Infinity; for (let k = i; k < l.p.length; k++) { const v = l.p[k]; if (v > hi) hi = v; if (v < lo) lo = v; }
    return { hi, lo };
  }

  spark(sid, ms, max) {
    const l = this.live.get(sid); if (!l || !l.t.length) return [];
    return downsample(this.liveRange(sid, l.t[l.t.length - 1] - ms), max).map(p => p[1]);
  }

  days() {
    try { return fs.readdirSync(this.histDir).filter(n => /^\d{4}-\d\d-\d\d$/.test(n)).sort(); } catch (e) { return []; }
  }

  series(sid, from, to) {
    if (to - from <= LIVE_MS + 1000) return this.liveRange(sid, from);
    const today = this.dk;
    let days;
    if (from <= 0) days = this.days();
    else { days = []; const d = new Date(from); d.setHours(0, 0, 0, 0); for (; d.getTime() <= to; d.setDate(d.getDate() + 1)) days.push(dayKey(d.getTime())); }
    const out = [];
    for (const dk of days) {
      if (dk === today) continue;
      const ck = dk + '|' + sid; let ser = this.dayCache.get(ck);
      if (!ser) { ser = this.readDay(dk, safeName(sid), 5000); this.dayCache.set(ck, ser); }
      for (const pt of ser) if (pt[0] >= from) out.push(pt);
    }
    const mem = this.dayMem.get(safeName(sid)) || [];
    for (const pt of mem) if (pt[0] >= from) out.push(pt);
    const l = this.live.get(sid);
    if (l && l.t.length) { const lt = l.t[l.t.length - 1]; if (!out.length || lt > out[out.length - 1][0]) out.push([lt, l.p[l.p.length - 1]]); }
    out.sort((a, b) => a[0] - b[0]);
    return out;
  }

  history(sid, range, max = 1600) {
    const to = Date.now();
    let from;
    if (range === 'all') from = 0; else if (SPANS[range]) from = to - SPANS[range] * 1000; else { range = '15m'; from = to - 900000; }
    let pts = downsample(this.series(sid, from, to), max);
    if (range === 'all' && pts.length) from = pts[0][0];
    const trades = this.allTrades(from).filter(x => x[1] === sid);
    return { stock: sid, range, from, to, points: pts, trades };
  }

  allTrades(from = 0) {
    const out = [];
    const start = from > 0 ? dayKey(from) : '';
    for (const dk of this.days()) {
      if (dk === this.dk || dk < start) continue;
      let tl = this.tradeCache.get(dk);
      if (!tl) { tl = this.readTrades(path.join(this.histDir, dk, 'trades.csv')); this.tradeCache.set(dk, tl); }
      for (const x of tl) if (x[0] >= from) out.push(x);
    }
    for (const x of this.trades) if (x[0] >= from) out.push(x);
    return out;
  }
}

module.exports = { HistoryStore, SPANS, LIVE_MS };
