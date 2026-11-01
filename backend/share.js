'use strict';
// shared 24/7 price tracking (same protocol as StockPilot 1.1 and server/worker.js):
//   POST /v1/upload   "v1 <id>\n<minuteMs> $SID:p0,...,p59;$SID2:...\n"
//   GET  /v1/status   "v1 <serverNowMs> <latestMinuteMs>"
//   GET  /v1/range?from&to  "v1\n<minuteMs> <data>\n..."   (several players per minute -> median)
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { dayKey, safeName, mkdirp } = require('./util');

const DEFAULT_URL = 'https://stockpilot.alisaandhomiayt.workers.dev';
const LOOKBACK_MS = 7 * 86400000;
const UP_EVERY_MIN = 5;
const SID_RE = /^\$[A-Za-z0-9_]{1,16}$/;

// merge /v1/range body into points inside the gaps; returns {out: Map sid->[[localMs, price]], spans}
function merge(body, gaps, off) {
  const rows = new Map();
  for (const raw of body.split('\n')) {
    const line = raw.replace(/\r$/, '');
    if (line.length < 3 || line.startsWith('v1')) continue;
    const sp = line.indexOf(' '); if (sp < 1) continue;
    const m = Number(line.slice(0, sp)); if (!Number.isFinite(m)) continue;
    if (!rows.has(m)) rows.set(m, []);
    rows.get(m).push(line.slice(sp + 1));
  }
  const out = new Map(), prev = new Map(), spans = [];
  const minutes = [...rows.keys()].sort((a, b) => a - b);
  for (const minute of minutes) {
    let inGap = false;
    for (let g = 0; g + 1 < gaps.length; g += 2) if (minute + 60000 > gaps[g] && minute < gaps[g + 1]) inGap = true;
    if (!inGap) continue;
    const parsed = [], sids = [];
    for (const d0 of rows.get(minute)) {
      let d = d0, res = 1;
      if (d.startsWith('r')) { const bar = d.indexOf('|'); const r = parseInt(d.slice(1, bar), 10); res = bar >= 2 && r >= 1 ? r : 1; d = d.slice(bar + 1); }
      const one = new Map();
      for (const part of d.split(';')) {
        const c = part.indexOf(':'); if (c < 2) continue;
        const sid = part.slice(0, c), vals = part.slice(c + 1).split(','), slots = new Float64Array(60);
        for (let i = 0; i < vals.length && i * res < 60; i++) { const v = parseFloat(vals[i]); if (vals[i].length && isFinite(v) && v > 0) slots[i * res] = v; }
        one.set(sid, slots); if (!sids.includes(sid)) sids.push(sid);
      }
      parsed.push(one);
    }
    let any = false;
    for (const sid of sids) {
      if (!out.has(sid)) out.set(sid, []);
      const dest = out.get(sid);
      let hasPrev = prev.has(sid), pv = prev.get(sid);
      for (let i = 0; i < 60; i++) {
        const vs = [];
        for (const one of parsed) { const sl = one.get(sid); if (sl && sl[i] > 0) vs.push(sl[i]); }
        if (!vs.length) continue;
        let v;
        if (vs.length === 1) v = vs[0];
        else if (vs.length === 2) {
          const a = vs[0], b = vs[1];
          if (Math.abs(a - b) <= 0.1 * Math.max(a, b)) v = (a + b) / 2;
          else if (hasPrev) v = Math.abs(a - pv) <= Math.abs(b - pv) ? a : b;
          else continue;
        } else { vs.sort((x, y) => x - y); v = vs[Math.floor(vs.length / 2)]; }
        pv = v; hasPrev = true;
        const t = minute + i * 1000;
        let keep = false;
        for (let g = 0; g + 1 < gaps.length; g += 2) if (t >= gaps[g] && t < gaps[g + 1]) keep = true;
        if (keep) { dest.push([t - off, v]); any = true; }
      }
      if (hasPrev) prev.set(sid, pv);
    }
    if (any) { const a = minute, b = minute + 60000; if (spans.length && spans[spans.length - 1][1] >= a) spans[spans.length - 1][1] = b; else spans.push([a, b]); }
  }
  return { out, spans };
}

function fmt7(v) { return String(parseFloat(v.toPrecision(7))); }

class Share {
  constructor({ dataDir, store, log, fetchFn, settings }) {
    this.dataDir = dataDir; this.store = store; this.log = log || (() => { }); this.fetch = fetchFn;
    this.on = settings.on !== false; this.url = settings.url || ''; this.id = settings.id || crypto.randomBytes(16).toString('hex');
    this.off = +settings.clockOff || 0; this.offKnown = false;
    this.buf = new Map(); this.queue = []; this.req = null;
    const now = Date.now();
    this.nextUp = now + 20000; this.nextFill = now + 15000; this.nextStatus = now + 25000; this.nextSave = now + 60000;
    this.cover = []; this.coverDirty = false; this.plan = [];
    this.sent = 0; this.filledMs = 0; this.fails = 0; this.err = ''; this.latest = 0;
    this.onImport = null;
  }
  baseUrl() { return (this.url || DEFAULT_URL).replace(/\/+$/, ''); }
  active() { return !!(this.on && this.baseUrl()); }
  srvNow() { return Date.now() + this.off; }
  setClock(serverMs, localMs) {
    if (!(serverMs > 0 && localMs > 0)) return;
    const o = serverMs - localMs;
    this.off = this.offKnown ? 0.9 * this.off + 0.1 * o : o; this.offKnown = true;
  }

  // ---- coverage: which server-time ranges we already have
  coverMerge() {
    const c = this.cover.sort((a, b) => a[0] - b[0]), m = [];
    for (const iv of c) { if (m.length && iv[0] <= m[m.length - 1][1] + 1000) { if (iv[1] > m[m.length - 1][1]) m[m.length - 1][1] = iv[1]; } else m.push([iv[0], iv[1]]); }
    this.cover = m; this.coverDirty = true;
  }
  coverAdd(a, b) { if (b > a) { this.cover.push([a, b]); this.coverMerge(); } }
  coverExtend(t) {
    const c = this.cover;
    if (c.length) { const last = c[c.length - 1]; if (t >= last[0] && t <= last[1] + 25000) { if (t > last[1]) { last[1] = t; this.coverDirty = true; } return; } }
    this.coverAdd(t, t + 1000);
  }
  coverGaps(from, to) {
    const gaps = []; let p = from;
    for (const iv of this.cover) {
      if (iv[1] <= p) continue; if (iv[0] >= to) break;
      if (iv[0] - p >= 2000) gaps.push([p, iv[0]]);
      p = Math.max(p, iv[1]);
    }
    if (to - p >= 2000) gaps.push([p, to]);
    return gaps;
  }
  coverLoad() {
    const f = path.join(this.dataDir, 'coverage.txt');
    if (fs.existsSync(f)) {
      for (const line of fs.readFileSync(f, 'utf8').split('\n')) { const a = line.split(','); if (a.length === 2) { const x = +a[0], y = +a[1]; if (isFinite(x) && isFinite(y) && y > x) this.cover.push([x, y]); } }
    } else {
      // first run: what is already recorded (one stock per day is enough)
      const cut = dayKey(Date.now() - 8 * 86400000);
      for (const dk of this.store.days()) {
        if (dk < cut) continue;
        const dir = path.join(this.store.histDir, dk); let big = null, bs = -1;
        try { for (const f2 of fs.readdirSync(dir)) { if (!f2.endsWith('.csv') || f2 === 'trades.csv' || f2.endsWith('.shared.csv')) continue; const s = fs.statSync(path.join(dir, f2)).size; if (s > bs) { bs = s; big = f2; } } } catch (e) { }
        if (!big) continue;
        let a = null, b = null;
        for (const pt of this.store.readDay(dk, big.replace(/\.csv$/, ''), 0)) {
          const t = pt[0] + this.off;
          if (b !== null && t - b <= 25000) b = t; else { if (a !== null) this.cover.push([a, b + 1000]); a = t; b = t; }
        }
        if (a !== null) this.cover.push([a, b + 1000]);
      }
    }
    this.coverMerge();
  }
  coverSave() {
    if (!this.coverDirty) return;
    const old = this.srvNow() - LOOKBACK_MS - 86400000;
    const s = this.cover.filter(iv => iv[1] >= old).map(iv => Math.round(iv[0]) + ',' + Math.round(iv[1])).join('\n') + '\n';
    try { fs.writeFileSync(path.join(this.dataDir, 'coverage.txt'), s); this.coverDirty = false; } catch (e) { }
  }

  // ---- sending: prices collected per minute (60 one-second slots)
  addOne(srvT, sid, p) {
    if (srvT <= 0 || !(p > 0) || !SID_RE.test(sid)) return;
    const min = Math.floor(srvT / 60000) * 60000; let sec = Math.floor((srvT - min) / 1000); if (sec > 59) sec = 59;
    let mb = this.buf.get(min); if (!mb) { mb = new Map(); this.buf.set(min, mb); }
    let a = mb.get(sid); if (!a) { a = new Float64Array(60); mb.set(sid, a); }
    a[sec] = p;
  }
  flushBuf(srvNow, all) {
    for (const min of [...this.buf.keys()].sort((a, b) => a - b)) {
      if (!all && min + 65000 > srvNow) continue;
      const mb = this.buf.get(min); this.buf.delete(min);
      if (!this.on) continue;
      const parts = [];
      for (const sid of [...mb.keys()].sort()) {
        const a = mb.get(sid); let any = false; const vals = [];
        for (let i = 0; i < 60; i++) { if (a[i] > 0) { vals.push(fmt7(a[i])); any = true; } else vals.push(''); }
        if (any) parts.push(sid + ':' + vals.join(','));
      }
      if (parts.length) this.queue.push(String(min) + ' ' + parts.join(';'));
    }
    if (this.queue.length > 2880) this.queue.splice(0, this.queue.length - 2880);
  }

  async request(kind, method, url, body, meta) {
    const ctl = new AbortController(); const tm = setTimeout(() => ctl.abort(), 60000);
    try {
      const r = await this.fetch(url, { method, body: body || undefined, headers: body ? { 'Content-Type': 'text/plain; charset=utf-8' } : undefined, signal: ctl.signal });
      const text = await r.text();
      return { kind, ok: r.status === 200, status: r.status, text, meta, err: r.status === 200 ? '' : 'error ' + r.status + ': ' + text.slice(0, 80) };
    } catch (e) { return { kind, ok: false, status: 0, text: '', meta, err: e.name === 'AbortError' ? 'timed out' : String(e.message || e) }; }
    finally { clearTimeout(tm); }
  }

  plan_(srvNow) {
    const gaps = this.coverGaps(srvNow - LOOKBACK_MS, srvNow - 60000);
    const hours = [];
    for (let i = gaps.length - 1; i >= 0; i--) { const g = gaps[i]; for (let h = Math.floor((g[1] - 1) / 3600000); h >= Math.floor(g[0] / 3600000); h--) if (!hours.includes(h)) hours.push(h); }
    this.plan = [];
    for (const h of hours.slice(0, 24)) {
      const H = h * 3600000, flat = [];
      for (const g of gaps) { const a = Math.max(g[0], H), b = Math.min(g[1], H + 3600000); if (b > a) flat.push(a, b); }
      if (flat.length) this.plan.push([H, flat]);
    }
    this.nextFill = Date.now() + (hours.length > 24 ? 60000 : 600000);
  }

  importPoints(dict) {
    const hourAgo = Date.now() - 3 * 3600000; let n = 0;
    for (const [sid, pts] of dict) {
      if (!pts.length || !SID_RE.test(sid)) continue;
      const key = safeName(sid), byDay = new Map(), live = [];
      for (const pt of pts) {
        const dk = dayKey(pt[0]);
        byDay.set(dk, (byDay.get(dk) || '') + Math.round(pt[0]) + ',' + pt[1] + '\n');
        if (dk === this.store.dk) { let mem = this.store.dayMem.get(key); if (!mem) { mem = []; this.store.dayMem.set(key, mem); } mem.push(pt); }
        if (pt[0] >= hourAgo) live.push(pt);
        n++;
      }
      for (const [dk, text] of byDay) this.store.appendDayLines(dk, key + '.shared.csv', text);
      const mem = this.store.dayMem.get(key); if (mem) mem.sort((a, b) => a[0] - b[0]);
      if (live.length) this.store.insertLive(sid, live);
    }
    if (n && this.onImport) this.onImport(n);
  }

  done(r) {
    const now = Date.now();
    if (r.kind === 'up') {
      if (r.ok) { this.queue.splice(0, Math.min(r.meta, this.queue.length)); this.sent += r.meta; this.fails = 0; this.err = ''; this.nextUp = now + (this.queue.length ? 2000 : UP_EVERY_MIN * 60000); }
      else if (r.status === 400 || r.status === 413) { this.queue.splice(0, Math.min(r.meta, this.queue.length)); this.log('Shared server refused some prices: ' + r.err, 'warn'); this.nextUp = now + 30000; }
      else { this.fails++; this.err = r.err; this.nextUp = now + Math.min(10, this.fails) * 60000; }
    } else if (r.kind === 'status') {
      if (r.ok) { const a = r.text.trim().split(' '); if (a.length >= 3) this.latest = +a[2] || 0; this.err = ''; } else this.err = r.err;
    } else if (r.kind === 'range') {
      if (!r.ok) { this.err = r.err; this.plan = []; this.nextFill = now + 300000; return; }
      this.err = '';
      const flat = r.meta[1];
      const { out, spans } = merge(r.text, flat, this.off);
      this.importPoints(out);
      for (const sp of spans) {
        for (let g = 0; g + 1 < flat.length; g += 2) { const a = Math.max(sp[0], flat[g]), b = Math.min(sp[1], flat[g + 1]); if (b > a) this.filledMs += b - a; }
        this.cover.push([sp[0], sp[1]]);
      }
      // times nobody shared: mark them checked once 15+ minutes old so they are not asked again
      const lim = this.srvNow() - 900000;
      for (let g = 0; g + 1 < flat.length; g += 2) { const b = Math.min(flat[g + 1], lim); if (b > flat[g]) this.cover.push([flat[g], b]); }
      this.coverMerge();
    }
  }

  step() {
    if (!this.active() || !this.fetch) return;
    const now = Date.now(), srvNow = this.srvNow();
    this.flushBuf(srvNow, false);
    if (now >= this.nextSave) { this.nextSave = now + 60000; this.coverSave(); }
    if (this.req) return;
    const u = this.baseUrl();
    const go = (p) => { this.req = p; p.then(r => { this.req = null; try { this.done(r); } catch (e) { this.err = String(e.message || e); } }); };
    if (this.queue.length && now >= this.nextUp) {
      const n = Math.min(15, this.queue.length);
      return go(this.request('up', 'POST', u + '/v1/upload', 'v1 ' + this.id + '\n' + this.queue.slice(0, n).join('\n') + '\n', n));
    }
    if (now >= this.nextStatus) { this.nextStatus = now + 1800000; return go(this.request('status', 'GET', u + '/v1/status', null, null)); }
    if (!this.plan.length && now >= this.nextFill) this.plan_(srvNow);
    if (this.plan.length) {
      const it = this.plan.shift(), fl = it[1];
      const from = Math.floor(fl[0] / 60000) * 60000, to = Math.ceil(fl[fl.length - 1] / 60000) * 60000;
      return go(this.request('range', 'GET', u + '/v1/range?from=' + from + '&to=' + to, null, it));
    }
  }

  message() {
    if (!this.on) return 'Off. Prices from times your game was closed are not filled in.';
    if (this.err) return "Can't reach the shared server right now (" + this.err + '). Retrying automatically.';
    const f = this.filledMs / 60000, ft = f >= 90 ? (f / 60).toFixed(1) + ' h' : Math.round(f) + ' min';
    let msg = 'On. This session: sent ' + this.sent + ' min of prices, filled ' + ft + ' of gaps.';
    if (this.latest > 0) {
      const ago = Math.max(0, (this.srvNow() - this.latest - 60000) / 60000);
      msg += ago < 3 ? ' Other players are sharing right now.' : ago < 120 ? ' Latest shared prices: ' + Math.round(ago) + ' min ago.' : ' Latest shared prices: ' + (ago / 60).toFixed(1) + ' h ago.';
    }
    return msg;
  }

  saveQueue() {
    this.flushBuf(this.srvNow(), true);
    const f = path.join(this.dataDir, 'share-queue.txt');
    try { if (this.queue.length) fs.writeFileSync(f, this.queue.join('\n') + '\n'); else if (fs.existsSync(f)) fs.unlinkSync(f); } catch (e) { }
  }
  loadQueue() {
    const f = path.join(this.dataDir, 'share-queue.txt');
    try { if (fs.existsSync(f)) { for (const l of fs.readFileSync(f, 'utf8').split('\n')) if (l) this.queue.push(l); fs.unlinkSync(f); } } catch (e) { }
  }
}

module.exports = { Share, merge, DEFAULT_URL };
