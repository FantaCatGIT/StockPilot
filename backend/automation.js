'use strict';
// Auto actions: "buy/sell/short/cover/close <stock> when price is below/above X" (same rules as 1.x)
const fs = require('fs');
const { num, norm, readJson, writeJson } = require('./util');

const ACTIONS = ['buy', 'sell', 'short', 'cover', 'close'];

function normalize(r) {
  if (!r) return null;
  let pct = 100; if (r.percent !== undefined && r.percent !== null && String(r.percent) !== '') pct = Math.round(Math.max(1, Math.min(100, num(r.percent))));
  return { stock: String(r.stock || '').trim(), action: String(r.action || '').trim().toLowerCase(), when: String(r.when || '').trim().toLowerCase(), price: num(r.price), percent: pct, repeat: r.repeat === true, enabled: r.enabled !== false };
}
function problem(n) {
  if (!n.stock) return 'pick a stock';
  if (!ACTIONS.includes(n.action)) return 'action must be buy, sell, short, cover or close';
  if (!['below', 'above'].includes(n.when)) return 'when must be below or above';
  if (!(n.price > 0)) return 'set a price';
  return null;
}
const keyOf = n => norm(n.stock) + '|' + n.action + '|' + n.when + '|' + n.price + '|' + n.percent;

class Automation {
  constructor({ file, log }) { this.file = file; this.log = log || (() => { }); this.dry = true; this.rules = []; this.armed = new Map(); this.warned = new Set(); this.version = 0; this.error = ''; }
  load() {
    const d = fs.existsSync(this.file) ? readJson(this.file) : { dry_run: true, rules: [] };
    if (!d) { this.error = 'automation.json has a typo (not valid JSON). Change any auto action here to re-save it.'; this.log(this.error, 'err'); return false; }
    this.setDoc(d.dry_run !== false, d.rules || [], false);
    return true;
  }
  setDoc(dry, rules, save = true) {
    const list = (rules || []).map(normalize).filter(Boolean);
    if (this.dry !== dry && this.version > 0) { this.armed.clear(); this.log(dry ? 'Mode: PRACTICE (nothing is traded)' : 'Mode: LIVE - auto actions really trade now', dry ? 'warn' : 'ok'); }
    this.dry = dry; this.rules = list; this.warned.clear(); this.error = ''; this.version++;
    if (save) { try { writeJson(this.file, { dry_run: this.dry, rules: this.rules }); } catch (e) { this.log('Could not save auto actions: ' + e.message, 'err'); } }
  }
  status() {
    return this.rules.map(n => { const k = keyOf(n); return { fired: this.armed.has(k) && !this.armed.get(k), problem: problem(n) }; });
  }
  // ctx: { stocks: Map id->stock, lookup: Map NORM->id, pos: Map id->{owned,shorted}, can(action,id)->bool, send(id, action, pct, src, dry)->bool }
  cycle(ctx) {
    let i = 0;
    for (const n of this.rules) {
      i++;
      if (!n.enabled || problem(n)) continue;
      const k = keyOf(n), sid = ctx.lookup.get(norm(n.stock));
      if (!sid) { if (!this.warned.has(k)) { this.warned.add(k); this.log(`Auto action ${i}: stock ${n.stock} not found in the game.`, 'warn'); } continue; }
      const s = ctx.stocks.get(sid); if (!s || s.unlocked === false) continue;
      const price = num(s.price);
      const hit = n.when === 'below' ? price < n.price : price > n.price;
      if (!hit) { this.armed.set(k, true); continue; }
      const isArmed = !this.armed.has(k) || this.armed.get(k);
      if (!isArmed && !n.repeat) continue;
      if (!ctx.can(n.action, sid)) continue;
      if (ctx.send(sid, n.action, n.percent, 'auto', this.dry, `${n.action.toUpperCase()} ${s.name || sid} ${n.percent >= 100 ? 'MAX' : n.percent + '%'} (price ${n.when} ${n.price})`)) this.armed.set(k, false);
    }
  }
}

module.exports = { Automation, normalize, problem, ACTIONS };
