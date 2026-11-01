'use strict';
// Experimental bot. Two strategies, both PRACTICE by default:
//  - Events: the game publishes scheduled price resets (pump/crash to a target). Shortly before one it can
//    close your longs and/or short (drop coming) or buy (rise coming), then exit after the event.
//  - Dip buyer: buys a picked stock when it falls X% under its recent average, sells at take-profit / stop-loss.
const fs = require('fs');
const { num, readJson, writeJson } = require('./util');

const DEFAULTS = {
  live: false,
  events: { enabled: false, leadSec: 60, closeLongs: true, shortDrops: false, buyRises: false, sizePct: 25, exitAfterSec: 20 },
  dip: { enabled: false, stocks: [], dipPct: 8, windowMin: 5, takeProfitPct: 6, stopLossPct: 8, sizePct: 25 },
};
const clamp = (v, a, b, d) => { v = num(v); return v >= a && v <= b ? v : d; };

class Bot {
  constructor({ file, log }) { this.file = file; this.log = log || (() => { }); this.cfg = JSON.parse(JSON.stringify(DEFAULTS)); this.occ = new Map(); this.pos = new Map(); this.st = new Map(); this.history = []; }
  load() { const d = readJson(this.file); if (d) this.set(d, false); }
  set(p, save = true) {
    const c = this.cfg;
    if (p.live !== undefined) { if (!!p.live !== c.live) { this.pos.clear(); this.log(p.live ? 'Bot is LIVE - it really trades now.' : 'Bot back to practice.', p.live ? 'ok' : 'warn'); } c.live = !!p.live; }
    if (p.events) { const e = p.events, ce = c.events;
      if (e.enabled !== undefined) ce.enabled = !!e.enabled; if (e.closeLongs !== undefined) ce.closeLongs = !!e.closeLongs; if (e.shortDrops !== undefined) ce.shortDrops = !!e.shortDrops; if (e.buyRises !== undefined) ce.buyRises = !!e.buyRises;
      if (e.leadSec !== undefined) ce.leadSec = clamp(e.leadSec, 5, 1800, 60); if (e.sizePct !== undefined) ce.sizePct = clamp(e.sizePct, 1, 100, 25); if (e.exitAfterSec !== undefined) ce.exitAfterSec = clamp(e.exitAfterSec, 0, 600, 20); }
    if (p.dip) { const d = p.dip, cd = c.dip;
      if (d.enabled !== undefined) cd.enabled = !!d.enabled; if (Array.isArray(d.stocks)) cd.stocks = d.stocks.map(String).slice(0, 40);
      for (const [k, a, b, def] of [['dipPct', 0.5, 90, 8], ['windowMin', 1, 180, 5], ['takeProfitPct', 0.2, 1000, 6], ['stopLossPct', 0.2, 95, 8], ['sizePct', 1, 100, 25]]) if (d[k] !== undefined) cd[k] = clamp(d[k], a, b, def); }
    if (save) { try { writeJson(this.file, c); } catch (e) { } }
  }
  note(text) { this.history.unshift({ t: Date.now(), text }); if (this.history.length > 100) this.history.length = 100; }

  // ctx: { stocks, pos, now (server ms), scheduled, avg(id, ms)->number|null, can(action,id), send(id, action, pct, src, dry, why)->bool, paused }
  cycle(ctx) {
    this.st.clear();
    const c = this.cfg, dry = !c.live;
    const send = (sid, action, pct, why) => { const ok = ctx.send(sid, action, pct, 'bot', dry, why); if (ok) this.note((dry ? '[practice] ' : '') + why); return ok; };
    // ---- events
    if (c.events.enabled) {
      for (const ev of ctx.scheduled) {
        const s = ctx.stocks.get(ev.stockId); if (!s || s.unlocked === false) continue;
        const price = num(s.price), target = num(ev.targetPrice), at = num(ev.scheduledAtMs), left = at - ctx.now;
        const drop = target < price * 0.97, rise = target > price * 1.03;
        const o = this.occ.get(ev.occurrenceId) || { pre: false, post: false, opened: null };
        this.occ.set(ev.occurrenceId, o);
        const p = ctx.pos.get(ev.stockId) || { owned: 0, shorted: 0 };
        const mm = Math.floor(Math.max(0, left) / 60000), ss = Math.floor((Math.max(0, left) % 60000) / 1000);
        let msg = `${drop ? 'Drop' : rise ? 'Rise' : 'Reset'} to ${target} in ${mm}:${String(ss).padStart(2, '0')}`;
        if (!o.pre && left <= c.events.leadSec * 1000 && left > -5000) {
          let did = true;
          if (drop) {
            if (c.events.closeLongs && (dry || p.owned > 0)) did = send(ev.stockId, 'sell', 100, `Events: sell ${s.name} before drop to ${target}`) && did;
            if (c.events.shortDrops && ctx.can('short', ev.stockId) && (dry || p.shorted <= 0)) { if (send(ev.stockId, 'short', c.events.sizePct, `Events: short ${s.name} before drop to ${target}`)) o.opened = 'short'; else did = false; }
          } else if (rise && c.events.buyRises && ctx.can('buy', ev.stockId)) { if (send(ev.stockId, 'buy', c.events.sizePct, `Events: buy ${s.name} before rise to ${target}`)) o.opened = 'long'; else did = false; }
          if (did) o.pre = true;
        }
        if (o.opened && !o.post && ctx.now > at + c.events.exitAfterSec * 1000) {
          if (o.opened === 'short' ? send(ev.stockId, 'cover', 100, `Events: cover ${s.name} after the reset`) : send(ev.stockId, 'sell', 100, `Events: sell ${s.name} after the reset`)) o.post = true;
        }
        if (o.pre) msg += o.opened ? ` · ${o.opened === 'short' ? 'shorted' : 'bought'}` : ' · done';
        else msg += ` · acts ${c.events.leadSec}s before`;
        this.st.set(ev.stockId, (this.st.get(ev.stockId) ? this.st.get(ev.stockId) + ' | ' : '') + msg);
      }
      for (const [k, o] of this.occ) if (!ctx.scheduled.some(e => e.occurrenceId === k) && (o.post || !o.opened)) this.occ.delete(k);
    }
    // ---- dip buyer
    if (c.dip.enabled) {
      for (const sid of c.dip.stocks) {
        const s = ctx.stocks.get(sid); if (!s || s.unlocked === false) continue;
        const price = num(s.price), avg = ctx.avg(sid, c.dip.windowMin * 60000), held = this.pos.get(sid);
        if (held) {
          const tp = held.entry * (1 + c.dip.takeProfitPct / 100), sl = held.entry * (1 - c.dip.stopLossPct / 100);
          if (price >= tp || price <= sl) {
            if (send(sid, 'sell', 100, `Dip: sell ${s.name} at ${price.toFixed(3)} (${price >= tp ? 'take-profit' : 'stop-loss'}, bought ${held.entry.toFixed(3)})`)) this.pos.delete(sid);
          }
          this.st.set(sid, `Holding from ${held.entry.toFixed(3)} · sells ≥ ${tp.toFixed(3)} or ≤ ${sl.toFixed(3)}`);
        } else if (avg) {
          const buyAt = avg * (1 - c.dip.dipPct / 100);
          const p = ctx.pos.get(sid) || { owned: 0 };
          if (price <= buyAt && ctx.can('buy', sid) && (dry || p.owned <= 0)) {
            if (send(sid, 'buy', c.dip.sizePct, `Dip: buy ${s.name} at ${price.toFixed(3)} (${c.dip.dipPct}% under its ${c.dip.windowMin}m average)`)) this.pos.set(sid, { entry: price, at: ctx.now });
          }
          this.st.set(sid, `Watching · avg ${avg.toFixed(3)} · buys ≤ ${buyAt.toFixed(3)}${p.owned > 0 && !dry ? ' (you already hold it - skipped)' : ''}`);
        } else this.st.set(sid, 'Collecting prices…');
      }
    }
  }
  status() { return { config: this.cfg, stocks: Object.fromEntries(this.st), history: this.history.slice(0, 40) }; }
}

module.exports = { Bot, DEFAULTS };
