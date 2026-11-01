'use strict';
/* StockPilot 2 - window UI. Talks to the app through window.sp (see preload.js). */
const $ = s => document.querySelector(s), $$ = s => [...document.querySelectorAll(s)];
const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const SUF = [[1e33, 'Dc'], [1e30, 'No'], [1e27, 'Oc'], [1e24, 'Sp'], [1e21, 'Sx'], [1e18, 'Qi'], [1e15, 'Qa'], [1e12, 'T'], [1e9, 'B'], [1e6, 'M'], [1e3, 'K']];
function big(n) {
  if (n == null || !isFinite(n)) return '–';
  const a = Math.abs(n); if (a >= 1e36) return n.toExponential(2);
  for (const [v, s] of SUF) if (a >= v) { const x = n / v; return (Math.abs(x) >= 100 ? x.toFixed(1) : x.toFixed(2)) + s; }
  return a >= 100 ? n.toFixed(1) : a >= 1 ? n.toFixed(2) : n.toFixed(4);
}
const money = n => n == null || !isFinite(n) ? '–' : (n < 0 ? '−$' : '$') + big(Math.abs(n));
const price = n => n == null || !isFinite(n) ? '–' : Math.abs(n) < 1e4 ? '$' + n.toFixed(3) : money(n);
const pct = (x, d) => x == null || !isFinite(x) ? '–' : (x > 0 ? '+' : x < 0 ? '−' : '') + Math.abs(x).toFixed(d != null ? d : Math.abs(x) >= 1000 ? 0 : Math.abs(x) >= 100 ? 1 : 2) + '%';
const signMoney = n => n == null || !isFinite(n) ? '–' : (n > 0 ? '+' : '') + money(n);
const tm = t => new Date(t).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
const dt = t => new Date(t).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
function ago(ms) { const s = Math.max(0, Math.round(ms / 1000)); if (s < 60) return s + 's ago'; if (s < 3600) return Math.floor(s / 60) + 'm ago'; if (s < 86400) return Math.floor(s / 3600) + 'h ago'; return Math.floor(s / 86400) + 'd ago'; }
function clock(sec) { sec = Math.max(0, Math.round(sec)); const h = Math.floor(sec / 3600), m = Math.floor(sec % 3600 / 60), s = sec % 60; return (h ? h + ':' + String(m).padStart(2, '0') : m) + ':' + String(s).padStart(2, '0'); }
const store = { get(k, d) { try { const v = localStorage.getItem('sp.' + k); return v == null ? d : JSON.parse(v); } catch (e) { return d; } }, set(k, v) { try { localStorage.setItem('sp.' + k, JSON.stringify(v)); } catch (e) { } } };
const SRC = { you: 'You (in game)', app: 'You (StockPilot)', auto: 'Auto action', bot: 'Bot' };
const ACT = { buy: 'Buy', sell: 'Sell', short: 'Short', cover: 'Cover', close: 'Close' };
const RANGES = ['1m', '5m', '15m', '1h', '3h', '6h', '24h', '7d', 'all'];

let S = null, offMs = 0, tab = 'market', colorCache = {};
const col = ci => colorCache[ci] || (colorCache[ci] = Charts.css('--c' + ((ci | 0) % 18)) || '#2563eb');
const stockById = id => S && S.stocks.find(s => s.id === id);
const srvNow = () => Date.now() + offMs;

function toast(msg) { const t = $('#toast'); t.textContent = msg; t.classList.add('show'); clearTimeout(toast._t); toast._t = setTimeout(() => t.classList.remove('show'), 3200); }
async function call(m, ...a) { try { return await sp.call(m, ...a); } catch (e) { toast(String(e.message || e).replace(/^Error invoking remote method 'sp': (Error: )?/, '')); throw e; } }
function seg(el, val, attr) { el.querySelectorAll('button').forEach(b => b.classList.toggle('sel', b.dataset[attr] === String(val))); }

/* ---------------- theme */
function applyTheme(t) {
  const dark = t === 'dark' || (t === 'system' && matchMedia('(prefers-color-scheme: dark)').matches);
  const v = dark ? 'dark' : 'light';
  if (document.documentElement.dataset.theme !== v) { document.documentElement.dataset.theme = v; colorCache = {}; redrawCharts(); }
}
matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => S && applyTheme(S.settings.theme));

/* ---------------- tabs */
$('#tabs').addEventListener('click', e => { const b = e.target.closest('button'); if (b) showTab(b.dataset.t); });
function showTab(t) {
  tab = t; store.set('tab', t);
  $$('#tabs button').forEach(b => b.classList.toggle('sel', b.dataset.t === t));
  $$('.tab').forEach(s => s.classList.toggle('sel', s.id === 't-' + t));
  onTab[t] && onTab[t]();
  render();
}
const onTab = {
  compare: () => loadCompare(), journal: () => loadJournal(), stats: () => loadStats(), dividends: () => loadStats(),
  news: () => { loadNews(); if (S) { store.set('newsSeen', S.news.steamLatest); } }, skins: () => loadSkins(),
};
setInterval(() => { if (tab === 'compare') loadCompare(); if (tab === 'stats' || tab === 'dividends') loadStats(); }, 5000);
setInterval(() => { if (tab === 'journal') loadJournal(true); }, 8000);

/* ---------------- header + strip */
$('#mode').addEventListener('click', e => { const b = e.target.closest('button'); if (b) setMode(b.dataset.m); });
$('#aMode').addEventListener('click', e => { const b = e.target.closest('button'); if (b) setMode(b.dataset.m); });
async function setMode(m) {
  if (!S) return; const live = m === 'live';
  if (live === !S.auto.dry) return;
  if (live && !confirm('Switch auto actions to LIVE?\n\nThey will really buy and sell in your game.')) return;
  await call('setAuto', !live, rules); S.auto.dry = !live; renderHeader(); renderAuto(true);
}
$('#pauseBtn').onclick = async () => { if (!S) return; S.paused = await call('setPaused', !S.paused); renderHeader(); };
$('#gameBtn').onclick = () => call('launchGame');

function renderHeader() {
  const c = $('#conn');
  c.className = 'conn ' + (S.connected ? 'on' : S.gameRunning ? 'warn' : '');
  c.querySelector('span').textContent = S.connected ? 'Connected' : S.status || 'Waiting for the game';
  $('#hCash').textContent = money(S.cash);
  $('#hNw').textContent = money(S.netWorth);
  $('#hToday').textContent = S.today ? signMoney(S.today.profit) + (S.today.pct != null ? '  ' + pct(S.today.pct) : '') : '–';
  $('#hLevel').textContent = S.level == null ? '–' : S.level;
  $('#hBuy').textContent = !S.connected ? '–' : S.cool.buy > 0.5 ? clock(S.cool.buy) : 'Ready';
  $('#hShort').textContent = !S.connected ? '–' : S.cool.short > 0.5 ? clock(S.cool.short) : 'Ready';
  seg($('#mode'), S.auto.dry ? 'practice' : 'live', 'm');
  const pb = $('#pauseBtn'); pb.textContent = S.paused ? 'Resume' : 'Pause'; pb.classList.toggle('on', S.paused);
  pb.title = S.paused ? 'Auto actions and the bot are paused' : 'Pause auto actions and the bot';
  const gb = $('#gameBtn'); gb.textContent = S.gameRunning ? 'Game is open' : 'Open game'; gb.classList.toggle('outline', !!S.gameRunning);
  // strip
  $('#stState').textContent = !S.connected ? 'OFFLINE' : S.paused ? 'PAUSED' : S.pendingCount ? 'WAITING FOR GAME' : 'IDLE';
  $('#stLast').textContent = 'Last actual: ' + (S.lastActual ? S.lastActual.text + ' · ' + ago(Date.now() - S.lastActual.t) : '–');
  $('#stResult').textContent = S.lastResult ? 'Game said: ' + S.lastResult.text : '';
  $('#stShare').textContent = S.share && S.share.on ? 'Price sharing: ' + S.share.msg.replace(/^On\.\s*/, '') : 'Price sharing off';
  $('#stGame').textContent = S.gameVersion ? 'Game v' + S.gameVersion : '';
  // banner (setup help)
  const bn = $('#banner'), msg = S.setup && S.setup.state !== 'ok' && S.setup.msg ? S.setup.msg : '';
  bn.classList.toggle('show', !!msg); bn.textContent = msg;
  // news badge
  const seen = store.get('newsSeen', ''), nb = $('#newsBadge');
  if (tab === 'news' && S.news.steamLatest) store.set('newsSeen', S.news.steamLatest);
  const fresh = S.news.steamLatest && seen !== S.news.steamLatest && tab !== 'news';
  nb.style.display = fresh ? '' : 'none'; nb.textContent = 'new';
}

/* ---------------- market grid */
const cards = new Map(); let order = '';
let sortBy = store.get('sort', 'game'), query = '';
seg($('#mSort'), sortBy, 's');
$('#mSort').addEventListener('click', e => { const b = e.target.closest('button'); if (!b) return; sortBy = b.dataset.s; store.set('sort', sortBy); seg($('#mSort'), sortBy, 's'); renderMarket(); });
$('#mSearch').addEventListener('input', e => { query = e.target.value.trim().toLowerCase(); renderMarket(); });
$('#mSize').addEventListener('click', e => { const b = e.target.closest('button'); if (b) setSize(+b.dataset.p); });
$('#setSize').addEventListener('click', e => { const b = e.target.closest('button'); if (b) setSize(+b.dataset.v); });
function tradeSize() { return S ? S.settings.tradeSize || 100 : 100; }
async function setSize(p) { if (!S) return; S.settings = await call('setSettings', { tradeSize: p }); seg($('#mSize'), p, 'p'); seg($('#setSize'), p, 'v'); seg($('#mdSize'), p, 'p'); }

function makeCard(s) {
  const el = document.createElement('div'); el.className = 'card stock';
  el.innerHTML = `<div class="r1"><span class="sym"></span><span class="nm faint"></span><span class="hl mono"></span></div>
  <div class="r2"><span class="px mono"></span><span class="ch">10s <b></b></span><span class="ch">1m <b></b></span><span class="ch">5m <b></b></span></div>
  <canvas class="spark"></canvas>
  <div class="pos"></div>
  <div class="btns"><button class="btn" data-a="buy">Buy</button><button class="btn outline" data-a="sell">Sell</button><button class="btn" data-a="short">Short</button><button class="btn outline" data-a="cover">Cover</button></div>
  <div class="foot"><span class="dv"></span><span class="au"></span><span class="botst"></span><span class="grow"></span><button class="link cl">Close all</button></div>`;
  const q = c => el.querySelector(c);
  const k = { el, sym: q('.sym'), nm: q('.nm'), hl: q('.hl'), px: q('.px'), ch: el.querySelectorAll('.ch b'), cv: q('canvas'), pos: q('.pos'), btn: {}, dv: q('.dv'), au: q('.au'), bot: q('.botst'), cl: q('.cl'), id: s.id, sig: '' };
  el.querySelectorAll('.btns button').forEach(b => { k.btn[b.dataset.a] = b; b.onclick = () => trade(k.id, b.dataset.a); });
  k.cl.onclick = () => trade(k.id, 'close');
  k.sym.onclick = k.cv.onclick = () => openDetail(k.id);
  return k;
}
function sorted(list) {
  const a = list.slice();
  if (sortBy === 'name') a.sort((x, y) => x.name.localeCompare(y.name));
  else if (sortBy === 'change') a.sort((x, y) => Math.abs(y.c5m || 0) - Math.abs(x.c5m || 0));
  else if (sortBy === 'held') a.sort((x, y) => (y.owned * y.price + y.shorted * y.price) - (x.owned * x.price + x.shorted * x.price));
  return a;
}
function renderMarket() {
  if (!S) return;
  const grid = $('#grid'), hide = S.settings.hideLocked;
  let list = S.stocks.filter(s => !(hide && !s.unlocked));
  if (query) list = list.filter(s => s.name.toLowerCase().includes(query) || s.id.toLowerCase().includes(query));
  list = sorted(list);
  const em = $('#gridEmpty');
  if (!list.length) { em.style.display = ''; em.textContent = S.stocks.length ? 'No stocks match.' : (S.status || 'Waiting for the game') + ' — prices show up here as soon as Screen Stocks is running.'; }
  else em.style.display = 'none';
  const key = list.map(s => s.id).join(',');
  for (const s of list) if (!cards.has(s.id)) cards.set(s.id, makeCard(s));
  if (key !== order) { order = key; grid.replaceChildren(...list.map(s => cards.get(s.id).el)); }
  const cool = S.cool, sz = tradeSize(), canTrade = S.connected;
  for (const s of list) {
    const k = cards.get(s.id), c = col(s.ci);
    k.el.style.setProperty('--sc', c);
    k.el.classList.toggle('locked', !s.unlocked); k.el.classList.toggle('pending', !!s.pending);
    k.sym.textContent = s.name; k.sym.title = s.name !== s.id ? 'Game id ' + s.id + ' · click for the chart' : 'Click for the chart';
    k.hl.textContent = s.hi > 0 ? 'H ' + price(s.hi).slice(1) + ' · L ' + price(s.lo).slice(1) : '';
    k.hl.title = 'High / low of the last 5 minutes';
    k.px.textContent = price(s.price);
    [s.c10s, s.c1m, s.c5m].forEach((v, i) => { k.ch[i].textContent = pct(v); });
    let pos = '';
    if (s.owned > 0) pos += `<div><span class="pill">LONG</span> <span class="mono">${esc(big(s.owned))} @ ${esc(price(s.avgBuy))}</span> · P/L <span class="mono">${esc(pct(s.plLPct))}</span> <span class="faint">(${esc(signMoney(s.plL))})</span></div>`;
    if (s.shorted > 0) pos += `<div><span class="pill grey">SHORT</span> <span class="mono">${esc(big(s.shorted))} @ ${esc(price(s.avgShort))}</span> · P/L <span class="mono">${esc(pct(s.plSPct))}</span> <span class="faint">(${esc(signMoney(s.plS))})</span></div>`;
    if (!pos) pos = `<span class="faint">${s.unlocked ? 'No position' : 'Locked in the game'}</span>`;
    if (k.posHtml !== pos) { k.pos.innerHTML = pos; k.posHtml = pos; }
    const lock = !canTrade || !s.unlocked || !!s.pending;
    const B = k.btn;
    B.buy.disabled = lock || cool.buy > 0.5; B.buy.textContent = cool.buy > 0.5 && canTrade ? 'Buy ' + Math.ceil(cool.buy) + 's' : 'Buy';
    B.short.disabled = lock || cool.short > 0.5; B.short.textContent = cool.short > 0.5 && canTrade ? 'Short ' + Math.ceil(cool.short) + 's' : 'Short';
    B.sell.disabled = lock || !(s.owned > 0); B.cover.disabled = lock || !(s.shorted > 0);
    k.cl.style.display = s.owned > 0 || s.shorted > 0 ? '' : 'none';
    B.buy.title = `Buy with ${sz}% of your cash`; B.short.title = `Short with ${sz}% of your cash`; B.sell.title = `Sell ${sz}% of your shares`; B.cover.title = `Cover ${sz}% of your short`;
    k.dv.textContent = s.div > 0 ? 'Dividend ' + (s.div * 100).toFixed(2) + '%' : '';
    const nAuto = rules.filter(r => r.enabled !== false && matchStock(r.stock, s)).length;
    k.au.textContent = nAuto ? nAuto + ' auto action' + (nAuto > 1 ? 's' : '') : '';
    const bs = S.bot.stocks && S.bot.stocks[s.id]; k.bot.textContent = bs ? 'Bot: ' + bs : '';
    const sig = s.spark.length + ':' + s.spark[s.spark.length - 1] + ':' + s.avgBuy + ':' + c + ':' + k.cv.clientWidth;
    if (sig !== k.sig) { k.sig = sig; Charts.spark(k.cv, s.spark, c, s.owned > 0 ? s.avgBuy : 0); }
  }
}
function matchStock(name, s) { const n = String(name || '').replace(/^\$/, '').toUpperCase(); return n === s.name.replace(/^\$/, '').toUpperCase() || n === s.id.replace(/^\$/, '').toUpperCase(); }
async function trade(id, action, pctOverride) {
  const s = stockById(id); if (!s) return;
  const p = action === 'close' ? 100 : (pctOverride || tradeSize());
  const what = `${ACT[action]} ${s.name}${action === 'close' ? '' : ' · ' + (p >= 100 ? 'MAX' : p + '%')}`;
  if (S.settings.confirmTrades && !confirm(what + '?')) return;
  const r = await call('trade', id, action, p);
  toast(r && r.ok ? what + ' — sent to the game' : (r && r.error) || 'Could not trade.');
}

/* ---------------- detail chart */
const md = { sid: null, range: store.get('mdRange', '15m'), h: null, hx: null, t: null, busy: false };
$('#mdRange').innerHTML = RANGES.map(r => `<button data-r="${r}">${r === 'all' ? 'All' : r}</button>`).join('');
$('#mdRange').addEventListener('click', e => { const b = e.target.closest('button'); if (!b) return; md.range = b.dataset.r; store.set('mdRange', md.range); seg($('#mdRange'), md.range, 'r'); loadDetail(); });
$('#mdSize').addEventListener('click', e => { const b = e.target.closest('button'); if (b) setSize(+b.dataset.p); });
$('#modal').querySelectorAll('[data-a]').forEach(b => b.onclick = () => trade(md.sid, b.dataset.a));
$('#mdClose').onclick = closeDetail;
$('#modal').addEventListener('mousedown', e => { if (e.target.id === 'modal') closeDetail(); });
document.addEventListener('keydown', e => { if (e.key === 'Escape') closeDetail(); });
Charts.hover($('#mdChart'), x => { md.hx = x; drawDetail(); });
function openDetail(id) { md.sid = id; md.h = null; seg($('#mdRange'), md.range, 'r'); seg($('#mdSize'), tradeSize(), 'p'); $('#modal').classList.add('show'); renderDetailInfo(); drawDetail(); loadDetail(); clearInterval(md.t); md.t = setInterval(loadDetail, 2000); }
function closeDetail() { $('#modal').classList.remove('show'); md.sid = null; clearInterval(md.t); }
async function loadDetail() {
  if (!md.sid || md.busy) return; md.busy = true;
  try { const h = await sp.call('history', md.sid, md.range); if (h && h.stock === md.sid) { md.h = h; drawDetail(); } } catch (e) { } finally { md.busy = false; }
}
function drawDetail() {
  if (!md.sid) return; const s = stockById(md.sid), h = md.h, c = s ? col(s.ci) : '#2563eb';
  if (!h) { Charts.line($('#mdChart'), { series: [], from: 0, to: 1, yFmt: price, empty: 'Loading…' }); return; }
  const hl = [];
  if (h.owned > 0 && h.avgBuy > 0) hl.push({ v: h.avgBuy, label: 'Avg buy ' + price(h.avgBuy), color: Charts.css('--blue') });
  if (h.shorted > 0 && h.avgShort > 0) hl.push({ v: h.avgShort, label: 'Avg short ' + price(h.avgShort), color: Charts.css('--v-short') });
  const marks = (h.trades || []).map(([t, a, q, p]) => ({ t, v: p, up: a === 'buy' || a === 'cover', color: a === 'buy' || a === 'cover' ? Charts.css('--blue') : Charts.css('--v-short') }));
  Charts.line($('#mdChart'), { series: [{ pts: h.points, color: c, name: s ? s.name : md.sid }], from: h.from, to: h.to, yFmt: price, hlines: hl, marks, gap: Math.max(90000, (h.to - h.from) / 120), hoverX: md.hx });
}
function renderDetailInfo() {
  if (!md.sid) return; const s = stockById(md.sid); if (!s) return;
  $('#mdDot').style.background = col(s.ci); $('#mdSym').textContent = s.name; $('#mdSym').style.color = col(s.ci);
  $('#mdPx').textContent = price(s.price); $('#mdSub').textContent = (s.name !== s.id ? s.id + ' · ' : '') + (s.unlocked ? '' : 'locked · ') + '1m ' + pct(s.c1m) + ' · 5m ' + pct(s.c5m) + ' · 1h ' + pct(s.c1h);
  const items = [['5m high', price(s.hi)], ['5m low', price(s.lo)], ['Base price', price(s.base)], ['Price cap', price(s.cap)], ['Dividend', s.div ? (s.div * 100).toFixed(2) + '%' : '–'], ['Shares for sale', big(s.avail)]];
  if (s.owned > 0) items.push(['You own', big(s.owned)], ['Avg buy', price(s.avgBuy)], ['Value', money(s.owned * s.price)], ['P/L', pct(s.plLPct) + ' (' + signMoney(s.plL) + ')']);
  if (s.shorted > 0) items.push(['Shorted', big(s.shorted)], ['Avg short', price(s.avgShort)], ['Short P/L', pct(s.plSPct) + ' (' + signMoney(s.plS) + ')']);
  $('#mdInfo').innerHTML = items.map(([a, b]) => `<div class="tile" style="padding:8px 12px;min-width:120px"><span>${esc(a)}</span><b style="font-size:15px">${esc(b)}</b></div>`).join('');
  const cool = S.cool, lock = !S.connected || !s.unlocked || !!s.pending;
  $('#modal').querySelector('[data-a=buy]').disabled = lock || cool.buy > 0.5;
  $('#modal').querySelector('[data-a=short]').disabled = lock || cool.short > 0.5;
  $('#modal').querySelector('[data-a=sell]').disabled = lock || !(s.owned > 0);
  $('#modal').querySelector('[data-a=cover]').disabled = lock || !(s.shorted > 0);
  $('#modal').querySelector('[data-a=close]').disabled = lock || !(s.owned > 0 || s.shorted > 0);
}

/* ---------------- compare */
const cmp = { sel: new Set(store.get('cmpSel', [])), range: store.get('cmpRange', '1h'), data: null, hx: null, busy: false };
$('#cRange').innerHTML = RANGES.map(r => `<button data-r="${r}">${r === 'all' ? 'All' : r}</button>`).join('');
seg($('#cRange'), cmp.range, 'r');
$('#cRange').addEventListener('click', e => { const b = e.target.closest('button'); if (!b) return; cmp.range = b.dataset.r; store.set('cmpRange', cmp.range); seg($('#cRange'), cmp.range, 'r'); loadCompare(); });
$('#cLegend').addEventListener('click', e => { const sp_ = e.target.closest('[data-id]'); if (!sp_) return; const id = sp_.dataset.id; cmp.sel.has(id) ? cmp.sel.delete(id) : cmp.sel.add(id); saveCmp(); });
$('#cAll').onclick = () => { S.stocks.filter(s => s.unlocked).forEach(s => cmp.sel.add(s.id)); saveCmp(); };
$('#cNone').onclick = () => { cmp.sel.clear(); saveCmp(); };
$('#cHeld').onclick = () => { cmp.sel = new Set(S.stocks.filter(s => s.owned > 0 || s.shorted > 0).map(s => s.id)); saveCmp(); };
Charts.hover($('#cChart'), x => { cmp.hx = x; drawCompare(); });
function saveCmp() { store.set('cmpSel', [...cmp.sel]); renderCompareLegend(); loadCompare(); }
function renderCompareLegend() {
  if (!S) return;
  if (!cmp.sel.size && !store.get('cmpTouched', false) && S.stocks.length) { const held = S.stocks.filter(s => s.owned > 0 || s.shorted > 0); (held.length ? held : S.stocks.filter(s => s.unlocked).slice(0, 5)).forEach(s => cmp.sel.add(s.id)); store.set('cmpTouched', true); }
  $('#cLegend').innerHTML = S.stocks.filter(s => s.unlocked || cmp.sel.has(s.id)).map(s => `<span data-id="${esc(s.id)}" style="opacity:${cmp.sel.has(s.id) ? 1 : .4}"><i class="dot" style="background:${col(s.ci)}"></i><b style="color:${col(s.ci)}">${esc(s.name)}</b></span>`).join('');
}
async function loadCompare() {
  if (!S || cmp.busy) return; renderCompareLegend(); cmp.busy = true;
  try { cmp.data = await sp.call('compare', [...cmp.sel], cmp.range); drawCompare(); } catch (e) { } finally { cmp.busy = false; }
}
function drawCompare() {
  const cv = $('#cChart'); if (!cmp.data || !S) return;
  const series = []; let from = Infinity, to = Date.now();
  for (const id of Object.keys(cmp.data.series)) {
    if (!cmp.sel.has(id)) continue;
    const pts = cmp.data.series[id]; if (!pts.length) continue; const s = stockById(id), b = pts[0][1]; if (!(b > 0)) continue;
    series.push({ pts: pts.map(p => [p[0], (p[1] / b - 1) * 100]), color: s ? col(s.ci) : '#888', name: s ? s.name : id }); from = Math.min(from, pts[0][0]);
  }
  if (cmp.range !== 'all') { const span = { '1m': 60e3, '5m': 300e3, '15m': 900e3, '1h': 3600e3, '3h': 10800e3, '6h': 21600e3, '24h': 86400e3, '7d': 604800e3 }[cmp.range]; from = to - span; }
  if (!isFinite(from)) from = to - 3600e3;
  Charts.line(cv, { series, from, to, yFmt: v => pct(v), zero: true, signed: true, gap: Math.max(90000, (to - from) / 120), hoverX: cmp.hx, empty: cmp.sel.size ? 'No prices recorded for this time range yet.' : 'Pick stocks below to compare them.' });
}

/* ---------------- portfolio */
function renderPortfolio() {
  const held = S.stocks.filter(s => s.owned > 0 || s.shorted > 0);
  const longV = held.reduce((a, s) => a + s.owned * s.price, 0), shortV = held.reduce((a, s) => a + s.shorted * s.price, 0);
  const cost = held.reduce((a, s) => a + s.owned * s.avgBuy + s.shorted * s.avgShort, 0), upl = held.reduce((a, s) => a + s.plL + s.plS, 0);
  const tiles = [['Cash', money(S.cash), '--v-cash'], ['Net worth', money(S.netWorth), '--v-nw'], ['In stocks (long)', money(longV), '--c4'], ['Shorted', money(shortV), '--v-short'], ['Open P/L', signMoney(upl), '--v-today', cost > 0 ? pct(upl / cost * 100) + ' of what you put in' : ''], ['Positions', String(held.length), '--v-level']];
  $('#pTiles').innerHTML = tiles.map(([a, b, c, sm]) => `<div class="tile"><span>${esc(a)}</span><b style="color:var(${c})">${esc(b)}</b>${sm ? `<small>${esc(sm)}</small>` : ''}</div>`).join('');
  const parts = held.filter(s => s.owned > 0).map(s => ({ n: s.name, v: s.owned * s.price, c: col(s.ci) }));
  if (S.cash > 0) parts.push({ n: 'Cash', v: S.cash, c: Charts.css('--faint') });
  const tot = parts.reduce((a, p) => a + p.v, 0) || 1;
  $('#pAlloc').innerHTML = parts.map(p => `<div title="${esc(p.n)} ${esc((p.v / tot * 100).toFixed(1))}%" style="width:${(p.v / tot * 100).toFixed(3)}%;background:${p.c}"></div>`).join('');
  $('#pAllocLegend').innerHTML = parts.map(p => `<span><i class="dot" style="background:${p.c}"></i>${esc(p.n)} <span class="mono muted">${esc((p.v / tot * 100).toFixed(1))}%</span></span>`).join('');
  const rows = [];
  for (const s of held) {
    if (s.owned > 0) rows.push([s, 'Long', s.owned, s.avgBuy, s.owned * s.price, s.plL, s.plLPct, 'sell']);
    if (s.shorted > 0) rows.push([s, 'Short', s.shorted, s.avgShort, s.shorted * s.price, s.plS, s.plSPct, 'cover']);
  }
  $('#pTable').innerHTML = `<tr><th>Stock</th><th>Side</th><th class="r">Shares</th><th class="r">Avg price</th><th class="r">Price</th><th class="r">Value</th><th class="r">P/L</th><th class="r">P/L %</th><th></th></tr>` +
    (rows.length ? rows.map(([s, side, q, avg, val, pl, plp, act]) => `<tr><td><i class="dot" style="background:${col(s.ci)}"></i><a class="sym" data-open="${esc(s.id)}" style="color:${col(s.ci)}">${esc(s.name)}</a></td><td><span class="pill ${side === 'Short' ? 'grey' : ''}">${side.toUpperCase()}</span></td><td class="r mono">${esc(big(q))}</td><td class="r mono">${esc(price(avg))}</td><td class="r mono">${esc(price(s.price))}</td><td class="r mono">${esc(money(val))}</td><td class="r mono">${esc(signMoney(pl))}</td><td class="r mono"><b>${esc(pct(plp))}</b></td><td class="r"><button class="btn outline sm" data-tr="${esc(s.id)}" data-a="${act}" data-p="50">${act === 'sell' ? 'Sell' : 'Cover'} 50%</button> <button class="btn sm" data-tr="${esc(s.id)}" data-a="${act}" data-p="100">${act === 'sell' ? 'Sell' : 'Cover'} all</button></td></tr>`).join('')
      : `<tr><td colspan="9" class="empty">You don't hold any stocks right now.</td></tr>`);
}
document.addEventListener('click', e => {
  const o = e.target.closest('[data-open]'); if (o && o.tagName === 'A') { openDetail(o.dataset.open); return; }
  const t = e.target.closest('[data-tr]'); if (t) trade(t.dataset.tr, t.dataset.a, +t.dataset.p);
});

/* ---------------- stats + dividends */
let ST = null, stBusy = false;
async function loadStats() { if (stBusy) return; stBusy = true; try { ST = await sp.call('stats'); renderStats(); renderDividends(); } catch (e) { } finally { stBusy = false; } }
function renderStats() {
  if (!ST || tab !== 'stats') return;
  const best = ST.daily.reduce((b, d) => !b || d.profit > b.profit ? d : b, null);
  const tiles = [['Trades', String(ST.tradeCount), '--v-level'], ['Realized P/L', signMoney(ST.realized), '--v-today', ST.closes + ' closed trades'], ['Win rate', ST.winRate == null ? '–' : ST.winRate.toFixed(1) + '%', '--v-nw', ST.wins + ' wins'], ['Dividends', money(ST.income.total), '--v-cash', ST.income.count + ' payouts'], ['Days tracked', String(ST.daily.length), '--c4'], ['Best day', best ? signMoney(best.profit) : '–', '--v-buy', best ? best.date : '']];
  $('#sTiles').innerHTML = tiles.map(([a, b, c, sm]) => `<div class="tile"><span>${esc(a)}</span><b style="color:var(${c})">${esc(b)}</b>${sm ? `<small>${esc(sm)}</small>` : ''}</div>`).join('');
  drawNw();
  $('#sDays').innerHTML = `<tr><th>Day</th><th class="r">Start</th><th class="r">End</th><th class="r">High</th><th class="r">Low</th><th class="r">Change</th><th class="r">%</th></tr>` +
    (ST.daily.length ? ST.daily.slice().reverse().map(d => `<tr><td>${esc(d.date)}</td><td class="r mono">${esc(money(d.start))}</td><td class="r mono">${esc(money(d.last))}</td><td class="r mono">${esc(money(d.high))}</td><td class="r mono">${esc(money(d.low))}</td><td class="r mono">${esc(signMoney(d.profit))}</td><td class="r mono"><b>${esc(pct(d.start ? d.profit / Math.abs(d.start) * 100 : null))}</b></td></tr>`).join('') : '<tr><td colspan="7" class="empty">No days yet.</td></tr>');
  $('#sStocks').innerHTML = `<tr><th>Stock</th><th class="r">Trades</th><th class="r">Realized P/L</th></tr>` +
    (ST.perStock.length ? ST.perStock.map(p => `<tr><td><i class="dot" style="background:${col(p.ci)}"></i><b style="color:${col(p.ci)}">${esc(p.name)}</b></td><td class="r mono">${p.n}</td><td class="r mono">${esc(signMoney(p.realized))}</td></tr>`).join('') : '<tr><td colspan="3" class="empty">No trades yet.</td></tr>');
  const tot = Object.values(ST.bySrc).reduce((a, b) => a + b, 0) || 1;
  $('#sSrc').innerHTML = Object.entries(ST.bySrc).map(([k, v], i) => `<div class="row" style="margin:6px 0"><span style="width:140px">${esc(SRC[k] || k)}</span><div class="alloc grow" style="margin:0"><div style="width:${v / tot * 100}%;background:var(--c${[0, 4, 2, 6][i % 4]})"></div></div><span class="mono" style="width:50px;text-align:right">${v}</span></div>`).join('') || '<div class="empty">No trades yet.</div>';
}
let nwHx = null;
Charts.hover($('#sNw'), x => { nwHx = x; drawNw(); });
function drawNw() { if (!ST) return; const pts = ST.nwSeries, to = Date.now(); Charts.line($('#sNw'), { series: [{ pts, color: Charts.css('--v-nw'), name: 'Net worth' }], from: pts.length ? Math.max(pts[0][0], to - 7 * 864e5) : to - 864e5, to, yFmt: money, gap: Math.max(90000, (to - (pts.length ? pts[0][0] : to)) / 150), hoverX: nwHx, empty: 'Net worth is recorded while the game is open.' }); }
function renderDividends() {
  if (!ST || !S || tab !== 'dividends') return; const inc = ST.income;
  const tiles = [['Received in total', money(inc.total), '--v-cash'], ['Last 24 hours', money(inc.day), '--v-nw'], ['Payouts', String(inc.count), '--v-level'], ['Usually every', inc.interval ? clock(inc.interval / 1000) : '–', '--c4']];
  $('#dTiles').innerHTML = tiles.map(([a, b, c]) => `<div class="tile"><span>${esc(a)}</span><b style="color:var(${c})">${esc(b)}</b></div>`).join('');
  $('#dTable').innerHTML = `<tr><th>When</th><th class="r">Amount</th></tr>` + (inc.recent.length ? inc.recent.map(([t, v]) => `<tr><td>${esc(dt(t))} <span class="faint">${esc(ago(Date.now() - t))}</span></td><td class="r mono">${esc(signMoney(v))}</td></tr>`).join('') : '<tr><td colspan="2" class="empty">No dividends seen yet. They are counted while StockPilot runs.</td></tr>');
  const list = S.stocks.filter(s => s.unlocked).sort((a, b) => b.div - a.div);
  $('#dRates').innerHTML = `<tr><th>Stock</th><th class="r">Dividend rate</th><th class="r">You hold</th><th class="r">Per payout (est.)</th></tr>` + list.map(s => `<tr><td><i class="dot" style="background:${col(s.ci)}"></i><b style="color:${col(s.ci)}">${esc(s.name)}</b></td><td class="r mono">${(s.div * 100).toFixed(2)}%</td><td class="r mono">${s.owned > 0 ? esc(money(s.owned * s.price)) : '–'}</td><td class="r mono">${s.owned > 0 ? esc(money(s.owned * s.price * s.div)) : '–'}</td></tr>`).join('');
}

/* ---------------- journal */
let JN = null, jSub = 'trades', jBusy = false;
$('#jSub').addEventListener('click', e => { const b = e.target.closest('button'); if (!b) return; jSub = b.dataset.j; seg($('#jSub'), jSub, 'j'); ['trades', 'notes', 'activity'].forEach(k => $('#j-' + k).style.display = k === jSub ? '' : 'none'); $('#jStock').style.display = $('#jSrc').style.display = jSub === 'trades' ? '' : 'none'; renderJournal(); });
$('#jStock').onchange = $('#jSrc').onchange = () => renderJournal();
const today = () => { const d = new Date(); return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0'); };
$('#jDate').value = today();
$('#jDate').onchange = () => { $('#jNote').value = (JN && JN.notes[$('#jDate').value]) || ''; $('#jSaved').textContent = ''; };
let noteT = null;
$('#jNote').addEventListener('input', () => { clearTimeout(noteT); $('#jSaved').textContent = 'Saving…'; noteT = setTimeout(async () => { const d = $('#jDate').value, v = $('#jNote').value; await call('setNote', d, v); if (JN) JN.notes[d] = v; $('#jSaved').textContent = 'Saved'; }, 600); });
async function loadJournal(quiet) {
  if (jBusy) return; jBusy = true;
  try { const j = await sp.call('journal'); const first = !JN; JN = j; if (first || !quiet) $('#jNote').value = JN.notes[$('#jDate').value] || ''; renderJournal(); } catch (e) { } finally { jBusy = false; }
}
function renderJournal() {
  if (!JN || !S) return;
  const sel = $('#jStock'), cur = sel.value, opts = '<option value="">All stocks</option>' + S.stocks.map(s => `<option value="${esc(s.id)}">${esc(s.name)}</option>`).join('');
  if (sel.dataset.o !== opts) { sel.innerHTML = opts; sel.dataset.o = opts; sel.value = cur; }
  if (jSub === 'trades') {
    const fs = sel.value, fsrc = $('#jSrc').value;
    const list = JN.trades.filter(t => (!fs || t.sid === fs) && (!fsrc || t.src === fsrc)).slice(0, 1500);
    $('#jTable').innerHTML = `<tr><th>Time</th><th>Stock</th><th>Action</th><th class="r">Shares</th><th class="r">Price</th><th class="r">Value</th><th>Who</th></tr>` +
      (list.length ? list.map(t => `<tr><td>${esc(dt(t.t))}</td><td><i class="dot" style="background:${col(t.ci)}"></i><a class="sym" data-open="${esc(t.sid)}" style="color:${col(t.ci)}">${esc(t.name)}</a></td><td><span class="pill ${t.action === 'sell' || t.action === 'short' ? 'grey' : ''}">${esc((ACT[t.action] || t.action).toUpperCase())}</span></td><td class="r mono">${esc(big(t.qty))}</td><td class="r mono">${esc(price(t.price))}</td><td class="r mono">${esc(money(t.qty * t.price))}</td><td>${esc(SRC[t.src] || t.src)}</td></tr>`).join('') : '<tr><td colspan="7" class="empty">No trades yet.</td></tr>');
  }
}
function renderLog(el, entries) {
  const key = entries.length ? entries[entries.length - 1].id + ':' + entries.length : '0';
  if (el.dataset.k === key) return; el.dataset.k = key;
  el.innerHTML = entries.slice().reverse().map(e => `<div><span class="tm">${esc(tm(e.t))}</span><span class="${esc(e.kind)}">${esc(e.msg)}</span></div>`).join('') || '<div class="faint">Nothing yet.</div>';
}

/* ---------------- news */
let NW = null, newsBusy = false, openNews = new Set();
$('#nRefresh').onclick = async () => { $('#nRefresh').disabled = true; try { NW = await call('refreshNews'); renderSteam(); } finally { $('#nRefresh').disabled = false; } };
async function loadNews() { if (newsBusy) return; newsBusy = true; try { NW = await sp.call('news'); renderSteam(); } catch (e) { } finally { newsBusy = false; } }
function renderSteam() {
  const el = $('#nSteam'); if (!NW) { el.innerHTML = '<div class="empty">Loading…</div>'; return; }
  if (!NW.items.length) { el.innerHTML = `<div class="empty">${NW.err ? 'Could not load announcements: ' + esc(NW.err) : 'No announcements yet.'}</div>`; return; }
  el.innerHTML = (NW.err ? `<div class="hint" style="margin-bottom:6px">Last refresh failed: ${esc(NW.err)}</div>` : '') + NW.items.map(n => `<div class="newsitem ${openNews.has(n.id) ? 'open' : ''}" data-n="${esc(n.id)}"><h4>${esc(n.title)}</h4><div class="hint" style="margin-bottom:6px">${esc(dt(n.date))}${n.author ? ' · ' + esc(n.author) : ''}</div><div class="body">${esc(n.text)}</div><div class="row" style="margin-top:6px"><button class="link" data-more>${openNews.has(n.id) ? 'Show less' : 'Read more'}</button>${n.url ? `<button class="link" data-url="${esc(n.url)}">Open on Steam</button>` : ''}</div></div>`).join('');
}
$('#nSteam').addEventListener('click', e => {
  const u = e.target.closest('[data-url]'); if (u) { call('openUrl', u.dataset.url); return; }
  if (e.target.closest('[data-more]')) { const it = e.target.closest('.newsitem'), id = it.dataset.n; openNews.has(id) ? openNews.delete(id) : openNews.add(id); renderSteam(); }
});
function renderNewsLive() {
  const off = offMs, mk = S.news.market;
  const m = mk.map(n => `<div class="row" style="padding:7px 0;border-bottom:1px solid var(--line2)"><span class="faint mono" style="width:64px">${esc(ago(srvNow() - n.t))}</span><i class="dot" style="background:${col(n.ci)}"></i><b style="color:${col(n.ci)};width:62px">${esc(n.name)}</b><span class="sig ${n.kind === 'high' ? 'hi' : 'lo'}">${n.kind === 'high' ? '▲ New high' : '▼ New low'}</span><span class="grow"></span><span class="mono">${esc(price(n.price))}</span><span class="faint">${n.look ? esc(n.look) + ' min' : ''}</span></div>`).join('');
  const mEl = $('#nMarket'); if (mEl.dataset.k !== mk.length + ':' + (mk[0] && mk[0].id) + ':' + Math.floor(Date.now() / 10000)) { mEl.dataset.k = mk.length + ':' + (mk[0] && mk[0].id) + ':' + Math.floor(Date.now() / 10000); mEl.innerHTML = m || '<div class="empty">No market news yet.</div>'; }
  const now = srvNow();
  $('#nSched').innerHTML = S.news.scheduled.length ? S.news.scheduled.map(e => {
    const left = (e.at - now) / 1000, s = stockById(e.sid), dir = String(e.dir || '').toLowerCase(), up = s && e.target > 0 ? e.target > s.price : (dir === 'pump' || dir === 'up' || dir === 'rise');
    return `<div style="padding:10px 0;border-bottom:1px solid var(--line2)"><div class="row"><i class="dot" style="background:${col(e.ci)}"></i><b style="color:${col(e.ci)}">${esc(e.name)}</b><span class="sig ${up ? 'hi' : 'lo'}">${up ? '▲ Jumps to target' : '▼ Drops to target'}</span><span class="grow"></span><span class="count" style="font-size:16px">${left > 0 ? clock(left) : 'now'}</span></div>
      <div class="hint" style="margin-top:3px">Target ${esc(price(e.target))}${s ? ' · now ' + esc(price(s.price)) + ' (' + esc(pct((e.target / s.price - 1) * 100)) + ')' : ''} · ${esc(new Date(e.at - off).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }))}</div></div>`;
  }).join('') : '<div class="empty">No scheduled events right now.</div>';
}

/* ---------------- auto actions */
let rules = [], rulesVer = -1, ruleT = null;
$('#aAdd').onclick = () => { const s = S && S.stocks.find(x => x.unlocked); rules.push({ stock: s ? s.name : '', action: 'buy', when: 'below', price: s ? +(s.price * 0.95).toPrecision(5) : 0, percent: 25, repeat: false, enabled: true }); saveRules(true); renderAuto(true); };
function saveRules(now) { clearTimeout(ruleT); const go = async () => { const r = await call('setAuto', S.auto.dry, rules); rulesVer = r.version; }; if (now) go(); else ruleT = setTimeout(go, 450); }
function renderAuto(force) {
  if (!S) return;
  seg($('#aMode'), S.auto.dry ? 'practice' : 'live', 'm');
  if (force || (S.auto.version !== rulesVer && !$('#aList').contains(document.activeElement))) {
    if (!force) rules = JSON.parse(JSON.stringify(S.auto.rules)); rulesVer = S.auto.version;
    const opts = S.stocks.map(s => `<option value="${esc(s.name)}">${esc(s.name)}</option>`).join('');
    $('#aList').innerHTML = rules.map((r, i) => `<div class="rule ${r.enabled === false ? 'off' : ''}" data-i="${i}">
      <div class="r1"><label class="sw" title="On / off"><input type="checkbox" data-k="enabled" ${r.enabled !== false ? 'checked' : ''}><span></span></label>
        <select data-k="action">${['buy', 'sell', 'short', 'cover', 'close'].map(a => `<option value="${a}" ${r.action === a ? 'selected' : ''}>${ACT[a]}</option>`).join('')}</select>
        <select data-k="stock">${opts}${S.stocks.some(s => s.name === r.stock) ? '' : `<option value="${esc(r.stock)}">${esc(r.stock || 'pick a stock')}</option>`}</select>
        <span>when the price is</span><select data-k="when"><option value="below" ${r.when === 'below' ? 'selected' : ''}>below</option><option value="above" ${r.when === 'above' ? 'selected' : ''}>above</option></select>
        <input type="number" data-k="price" step="any" min="0" value="${esc(r.price)}" style="width:120px">
        <button class="x" data-del title="Delete">×</button></div>
      <div class="r3"><span>Size</span><input type="number" data-k="percent" min="1" max="100" value="${esc(r.percent)}" style="width:70px"><span>%</span>
        <label class="row" style="gap:6px;margin-left:10px"><input type="checkbox" data-k="repeat" ${r.repeat ? 'checked' : ''}> Repeat every time it crosses</label>
        <span class="st" data-st></span></div></div>`).join('');
    $('#aList').querySelectorAll('select[data-k=stock]').forEach((el, i) => { el.value = rules[i].stock; });
  }
  $('#aEmpty').style.display = rules.length ? 'none' : '';
  $('#aList').querySelectorAll('.rule').forEach(el => {
    const i = +el.dataset.i, r = rules[i], st = (S.auto.status || [])[i], s = S.stocks.find(x => matchStock(r.stock, x)), o = el.querySelector('[data-st]');
    let txt = '', cls = '';
    if (st && st.problem) { txt = 'Fix: ' + st.problem; cls = 'bad'; }
    else if (r.enabled === false) { txt = 'Off'; cls = 'done'; }
    else if (st && st.fired && !r.repeat) { txt = 'Done — it fired once'; cls = 'done'; }
    else if (s) { const hit = r.when === 'below' ? s.price < r.price : s.price > r.price; txt = 'Now ' + price(s.price) + (hit ? ' · condition met' : ' · waiting'); cls = hit ? 'go' : ''; }
    o.textContent = txt; o.className = 'st ' + cls;
  });
}
$('#aList').addEventListener('input', e => {
  const el = e.target.closest('[data-k]'), row = e.target.closest('.rule'); if (!el || !row) return;
  const r = rules[+row.dataset.i], k = el.dataset.k;
  r[k] = el.type === 'checkbox' ? el.checked : el.type === 'number' ? +el.value : el.value;
  if (k === 'enabled') row.classList.toggle('off', !el.checked);
  saveRules(el.tagName === 'SELECT' || el.type === 'checkbox');
});
$('#aList').addEventListener('click', e => { if (!e.target.closest('[data-del]')) return; const row = e.target.closest('.rule'); rules.splice(+row.dataset.i, 1); saveRules(true); renderAuto(true); });

/* ---------------- bot */
$('#bLive').onchange = async e => {
  if (e.target.checked && !confirm('Let the bot really trade?\n\nIt is experimental. You can switch it back to practice any time.')) { e.target.checked = false; return; }
  S.bot = await call('botSet', { live: e.target.checked }); renderBot();
};
$('#t-bot').addEventListener('change', async e => {
  const k = e.target.dataset.b; if (!k) return; const [g, f] = k.split('.');
  const v = e.target.type === 'checkbox' ? e.target.checked : +e.target.value;
  S.bot = await call('botSet', { [g]: { [f]: v } }); renderBot();
});
$('#bStocks').addEventListener('click', async e => {
  const c = e.target.closest('[data-id]'); if (!c) return; const set = new Set(S.bot.config.dip.stocks); set.has(c.dataset.id) ? set.delete(c.dataset.id) : set.add(c.dataset.id);
  S.bot = await call('botSet', { dip: { stocks: [...set] } }); renderBot();
});
function renderBot() {
  const c = S.bot.config;
  $('#bLive').checked = !!c.live;
  $$('#t-bot [data-b]').forEach(el => { if (el === document.activeElement) return; const [g, f] = el.dataset.b.split('.'); const v = c[g][f]; if (el.type === 'checkbox') el.checked = !!v; else el.value = v; });
  const sel = new Set(c.dip.stocks);
  const chips = S.stocks.filter(s => s.unlocked || sel.has(s.id)).map(s => `<span data-id="${esc(s.id)}" class="pill ${sel.has(s.id) ? '' : 'grey'}" style="cursor:pointer;${sel.has(s.id) ? `background:${Charts.alpha(col(s.ci), .15)};color:${col(s.ci)}` : ''}">${esc(s.name)}</span>`).join('');
  if ($('#bStocks').dataset.k !== chips) { $('#bStocks').innerHTML = chips; $('#bStocks').dataset.k = chips; }
  const st = Object.entries(S.bot.stocks || {});
  $('#bStatus').innerHTML = st.length ? st.map(([id, msg]) => { const s = stockById(id); return `<div class="row" style="padding:6px 0;border-bottom:1px solid var(--line2)"><i class="dot" style="background:${s ? col(s.ci) : '#888'}"></i><b style="width:70px;color:${s ? col(s.ci) : ''}">${esc(s ? s.name : id)}</b><span>${esc(msg)}</span></div>`; }).join('') : `<div class="empty">${c.events.enabled || c.dip.enabled ? 'Watching… nothing to do yet.' : 'Turn on a strategy above.'}</div>`;
  renderLog($('#bHist'), (S.bot.history || []).slice().reverse().map((h, i) => ({ id: h.t + ':' + i, t: h.t, msg: h.text, kind: c.live ? 'ok' : '' })));
}

/* ---------------- skins */
const STATICCAP = 2560, ANIMCAP = 960, ANIMFPS = 10, ANIMMAXSEC = 15, ANIMMAXFRAMES = 150;
let skCanvas = null, skFrames = [], skFps = ANIMFPS, skBg = '#101018';
const hex2 = (r, g, b) => '#' + [r, g, b].map(v => Math.max(0, Math.min(255, Math.round(v))).toString(16).padStart(2, '0')).join('');
function rgb2hsv(r, g, b) { r /= 255; g /= 255; b /= 255; const mx = Math.max(r, g, b), mn = Math.min(r, g, b), d = mx - mn; let h = 0; if (d) { if (mx === r) h = ((g - b) / d) % 6; else if (mx === g) h = (b - r) / d + 2; else h = (r - g) / d + 4; h *= 60; if (h < 0) h += 360; } return [h, mx ? d / mx : 0, mx]; }
function hsv2rgb(h, s, v) { const c = v * s, x = c * (1 - Math.abs((h / 60) % 2 - 1)), m = v - c; const [r, g, b] = h < 60 ? [c, x, 0] : h < 120 ? [x, c, 0] : h < 180 ? [0, c, x] : h < 240 ? [0, x, c] : h < 300 ? [x, 0, c] : [c, 0, x]; return [(r + m) * 255, (g + m) * 255, (b + m) * 255]; }
function pickColors(src) {
  const c = document.createElement('canvas'); c.width = c.height = 48; const x = c.getContext('2d'); x.drawImage(src, 0, 0, 48, 48); const d = x.getImageData(0, 0, 48, 48).data;
  const bins = Array.from({ length: 12 }, () => ({ w: 0, h: 0 })); let ar = 0, ag = 0, ab = 0, n = 0;
  for (let i = 0; i < d.length; i += 4) { const r = d[i], g = d[i + 1], b = d[i + 2]; ar += r; ag += g; ab += b; n++; const [h, s, v] = rgb2hsv(r, g, b); const w = s * s * v, k = Math.floor(h / 30) % 12; bins[k].w += w; bins[k].h += h * w; }
  ar /= n; ag /= n; ab /= n; const best = bins.reduce((a, b) => b.w > a.w ? b : a); const [mh, ms] = rgb2hsv(ar, ag, ab); const hue = best.w > 1 ? best.h / best.w : mh;
  return { glow: hex2(...hsv2rgb(hue, best.w > 1 ? .75 : .15, .95)), panels: hex2(...hsv2rgb(mh, Math.min(ms, .35), .16)), buttons: hex2(...hsv2rgb(hue, Math.min(.45, best.w > 1 ? .45 : ms), .30)), bg: hex2(...hsv2rgb(mh, Math.min(ms, .3), .10)) };
}
// fit the whole picture onto a screen-shaped canvas so the game doesn't zoom in / crop it
function sTgt(cap) { const dpr = window.devicePixelRatio || 1; let w = Math.round((screen.width || 1600) * dpr), h = Math.round((screen.height || 900) * dpr); if (!(w > 1) || !(h > 1)) { w = 1920; h = 1080; } const mx = Math.max(w, h); if (mx > cap) { const s = cap / mx; w = Math.round(w * s); h = Math.round(h * s); } return [Math.max(2, w), Math.max(2, h)]; }
function fitCanvas(src, sw, sh, W, H, bg) { const c = document.createElement('canvas'); c.width = W; c.height = H; const x = c.getContext('2d'); x.fillStyle = bg; x.fillRect(0, 0, W, H); const s = Math.min(W / sw, H / sh), w = Math.round(sw * s), h = Math.round(sh * s); x.imageSmoothingEnabled = true; x.imageSmoothingQuality = 'high'; x.drawImage(src, 0, 0, sw, sh, Math.round((W - w) / 2), Math.round((H - h) / 2), w, h); return c; }
function nameFrom(fn) { return (fn.replace(/\.[^.]+$/, '').replace(/[^A-Za-z0-9 _\-.!]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 40)) || 'My skin'; }
function applyColors(k, fn) { $('#skPanels').value = k.panels; $('#skButtons').value = k.buttons; $('#skGlowC').value = k.glow; skBg = k.bg; if (fn) $('#skName').value = nameFrom(fn); }
function resetSkin() { skCanvas = null; skFrames = []; $('#skAnim').style.display = 'none'; }
function seekTo(v, t) { return new Promise(res => { let done = false; const on = () => { if (done) return; done = true; v.removeEventListener('seeked', on); res(); }; v.addEventListener('seeked', on); try { v.currentTime = t; } catch (e) { on(); } setTimeout(on, 1500); }); }
async function framesFromVideo(f) {
  const v = document.createElement('video'); v.muted = true; v.playsInline = true; v.preload = 'auto'; v.src = URL.createObjectURL(f);
  await new Promise((res, rej) => { v.onloadedmetadata = () => res(); v.onerror = () => rej(new Error('Could not read that video.')); });
  let dur = v.duration; if (!isFinite(dur) || dur <= 0) throw new Error('Could not read that video.'); dur = Math.min(ANIMMAXSEC, dur);
  await seekTo(v, 0); const vw = v.videoWidth, vh = v.videoHeight; if (!vw || !vh) { URL.revokeObjectURL(v.src); throw new Error('Could not read that video.'); }
  const first = document.createElement('canvas'); first.width = vw; first.height = vh; first.getContext('2d').drawImage(v, 0, 0, vw, vh);
  const k = pickColors(first); applyColors(k, f.name); const n = Math.max(1, Math.min(ANIMMAXFRAMES, Math.round(dur * ANIMFPS))); const [W, H] = sTgt(ANIMCAP); const frames = [];
  for (let i = 0; i < n; i++) { $('#skMsg').textContent = 'Reading video… ' + Math.round(i / n * 100) + '%'; await seekTo(v, dur * i / n); frames.push(fitCanvas(v, vw, vh, W, H, k.bg).toDataURL('image/jpeg', .82).split(',')[1]); }
  URL.revokeObjectURL(v.src); return { frames, fps: Math.max(1, Math.round(n / dur)) };
}
async function gifRawFrames(f) {
  const ab = await f.arrayBuffer();
  if (typeof ImageDecoder !== 'undefined') {
    try { const dec = new ImageDecoder({ data: ab, type: 'image/gif' }); await dec.completed; const tr = dec.tracks && dec.tracks.selectedTrack, total = (tr && tr.frameCount) || 1, raw = []; for (let i = 0; i < total; i++) { let r; try { r = await dec.decode({ frameIndex: i }); } catch (e) { break; } const im = r.image; raw.push({ img: im, w: im.displayWidth || im.codedWidth, h: im.displayHeight || im.codedHeight, dms: (im.duration || 100000) / 1000, close: () => { try { im.close(); } catch (e) { } } }); } if (raw.length > 1) return raw; raw.forEach(r => r.close()); } catch (e) { }
  }
  const g = decodeGif(ab); return g.frames.map(fr => { const c = document.createElement('canvas'); c.width = g.width; c.height = g.height; c.getContext('2d').putImageData(new ImageData(fr.data, g.width, g.height), 0, 0); return { img: c, w: g.width, h: g.height, dms: fr.delay, close: () => { } }; });
}
async function framesFromGif(f) {
  let raw; try { raw = await gifRawFrames(f); } catch (e) { return null; } if (!raw || raw.length < 2) { if (raw) raw.forEach(r => r.close()); return null; }
  const fc = document.createElement('canvas'); fc.width = raw[0].w; fc.height = raw[0].h; fc.getContext('2d').drawImage(raw[0].img, 0, 0); const k = pickColors(fc); applyColors(k, f.name);
  const [W, H] = sTgt(ANIMCAP); const tot = Math.min(ANIMMAXSEC * 1000, raw.reduce((a, r) => a + r.dms, 0)), step = 1000 / ANIMFPS, frames = []; let idx = 0, cum = raw[0].dms;
  for (let t = 0; t < tot && frames.length < ANIMMAXFRAMES; t += step) { while (idx < raw.length - 1 && t >= cum) { idx++; cum += raw[idx].dms; } frames.push(fitCanvas(raw[idx].img, raw[idx].w, raw[idx].h, W, H, k.bg).toDataURL('image/jpeg', .82).split(',')[1]); }
  raw.forEach(r => r.close()); return { frames, fps: ANIMFPS };
}
function staticImage(f) {
  return new Promise((res, rej) => {
    const url = URL.createObjectURL(f), im = new Image();
    im.onload = () => { const nw = im.naturalWidth, nh = im.naturalHeight; if (!nw || !nh) { URL.revokeObjectURL(url); return rej(new Error("Couldn't read that picture.")); }
      const native = document.createElement('canvas'); native.width = nw; native.height = nh; native.getContext('2d').drawImage(im, 0, 0); const k = pickColors(native); applyColors(k, f.name);
      const [W, H] = sTgt(STATICCAP); skCanvas = fitCanvas(im, nw, nh, W, H, k.bg); $('#skPrev').src = skCanvas.toDataURL('image/jpeg', .82); $('#skAnim').style.display = 'none'; $('#skForm').style.display = ''; URL.revokeObjectURL(url); res(); };
    im.onerror = () => { URL.revokeObjectURL(url); rej(new Error("Couldn't read that picture.")); }; im.src = url;
  });
}
function setAnim(r) { skFrames = r.frames; skFps = r.fps || ANIMFPS; skCanvas = null; $('#skPrev').src = 'data:image/jpeg;base64,' + r.frames[0]; const a = $('#skAnim'); a.style.display = ''; a.textContent = 'Animated · ' + r.frames.length + ' frames · ' + skFps + ' fps · loops while the game is open'; $('#skForm').style.display = ''; }
async function skinFile(f) {
  const m = $('#skMsg'); m.textContent = ''; resetSkin(); if (!f) return;
  const isVid = /^video\//.test(f.type) || /\.(mp4|webm|mov|m4v)$/i.test(f.name), isGif = f.type === 'image/gif' || /\.gif$/i.test(f.name);
  try { if (isVid) { m.textContent = 'Reading video…'; setAnim(await framesFromVideo(f)); m.textContent = ''; } else if (isGif) { m.textContent = 'Reading GIF…'; const r = await framesFromGif(f); if (r) setAnim(r); else await staticImage(f); m.textContent = ''; } else await staticImage(f); }
  catch (e) { resetSkin(); m.textContent = e.message || 'Could not read that file.'; $('#skForm').style.display = 'none'; }
}
$('#skPick').onclick = () => $('#skFile').click();
$('#skFile').onchange = e => { skinFile(e.target.files[0]); e.target.value = ''; };
const dz = $('#drop');
dz.addEventListener('dragover', e => { e.preventDefault(); dz.classList.add('over'); });
dz.addEventListener('dragleave', () => dz.classList.remove('over'));
dz.addEventListener('drop', e => { e.preventDefault(); dz.classList.remove('over'); if (e.dataTransfer.files[0]) skinFile(e.dataTransfer.files[0]); });
document.addEventListener('dragover', e => e.preventDefault()); document.addEventListener('drop', e => e.preventDefault());
function thumbFrom(dataURL) { return new Promise(res => { const img = new Image(); img.onload = () => { const sc = 320 / img.width, t = document.createElement('canvas'); t.width = 320; t.height = Math.max(1, Math.round(img.height * sc)); t.getContext('2d').drawImage(img, 0, 0, t.width, t.height); res(t.toDataURL('image/jpeg', .72)); }; img.onerror = () => res(''); img.src = dataURL; }); }
$('#skMake').onclick = async () => {
  const m = $('#skMsg'), b = $('#skMake'), anim = skFrames.length > 1; if (!skCanvas && !anim) return; const name = $('#skName').value.trim();
  if (!/^[A-Za-z0-9 _\-.!]{1,40}$/.test(name)) { m.textContent = 'Name: letters, numbers, spaces, - _ . ! only.'; return; }
  const list = await sp.call('skins').catch(() => []); const slug = 'sp-' + (name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || 'skin') + '.json';
  if (list.some(s => s.file === slug) && !confirm('A skin called "' + name + '" already exists. Replace it?')) return;
  b.disabled = true; m.textContent = 'Adding…';
  try {
    const meta = { name, panels: $('#skPanels').value, buttons: $('#skButtons').value, bg: skBg, frames: $('#skFrames').checked, glow: $('#skGlow').checked, glowColor: $('#skGlowC').value };
    if (anim) {
      meta.fps = skFps; meta.count = skFrames.length; meta.thumb = await thumbFrom('data:image/jpeg;base64,' + skFrames[0]);
      const base = await sp.call('skinAnimStart', meta);
      for (let i = 0; i < skFrames.length; i++) { m.textContent = 'Adding frame ' + (i + 1) + '/' + skFrames.length + '…'; await sp.call('skinAnimFrame', base, i, skFrames[i]); }
      await sp.call('skinAnimFinish', base, skFrames.length);
      m.textContent = 'Added! Pick "' + name + '" in the game’s skin settings — it loops while the game is open.';
    } else {
      meta.thumb = await thumbFrom(skCanvas.toDataURL('image/jpeg', .82));
      await sp.call('skinAdd', meta, skCanvas.toDataURL('image/png').split(',')[1]);
      m.textContent = 'Added! Pick "' + name + '" in the game’s skin settings.';
    }
    loadSkins();
  } catch (e) { m.textContent = String(e.message || e).replace(/^Error invoking remote method 'sp': (Error: )?/, ''); }
  finally { b.disabled = false; }
};
async function loadSkins() {
  let list = []; try { list = await sp.call('skins'); } catch (e) { }
  $('#skList').innerHTML = list.length ? list.map(s => `<div class="skrow" data-f="${esc(s.file)}">${s.thumb ? `<img src="${esc(s.thumb)}" alt="">` : '<div class="ph"></div>'}<div class="nm"><b>${esc(s.name)}</b><div class="hint">${s.anim ? 'Animated · ' : ''}${s.ours ? 'Made with StockPilot' : 'From another mod'}</div></div><label class="sw" title="Show in the game"><input type="checkbox" data-sk ${s.enabled ? 'checked' : ''}><span></span></label>${s.ours ? '<button class="btn ghost sm" data-skdel>Delete</button>' : ''}</div>`).join('') : '<div class="empty">No skins yet.</div>';
}
$('#skList').addEventListener('change', async e => { if (!e.target.matches('[data-sk]')) return; await call('skinSet', e.target.closest('.skrow').dataset.f, e.target.checked); });
$('#skList').addEventListener('click', async e => { if (!e.target.closest('[data-skdel]')) return; const f = e.target.closest('.skrow').dataset.f; if (!confirm('Delete this skin?')) return; await call('skinDel', f); loadSkins(); });
$('#skFolder').onclick = () => call('openFolder', 'skins');

/* ---------------- settings */
$('#setTheme').addEventListener('click', async e => { const b = e.target.closest('button'); if (!b) return; S.settings = await call('setSettings', { theme: b.dataset.v }); applyTheme(S.settings.theme); renderSettings(); });
$('#t-settings').addEventListener('change', async e => {
  const k = e.target.dataset.s; if (!k) return; const v = e.target.checked, patch = {}; const parts = k.split('.');
  let o = patch; parts.slice(0, -1).forEach(p => { o = o[p] = {}; }); o[parts[parts.length - 1]] = v;
  S.settings = await call('setSettings', patch); renderSettings(); renderMarket();
});
$('#shareUrl').addEventListener('change', async e => { const u = e.target.value.trim(); if (u && !/^https?:\/\/[A-Za-z0-9.\-:]+\/?$/.test(u)) { toast('Use a server address like https://name.workers.dev'); return; } S.settings = await call('setSettings', { share: { url: u } }); toast(u ? 'Server saved' : 'Using the default server'); });
$$('[data-open]').forEach(b => { if (b.tagName === 'BUTTON') b.onclick = () => call('openFolder', b.dataset.open); });
$('#quitBtn').onclick = () => { if (confirm('Quit StockPilot? Auto actions and the bot stop until you open it again.')) call('quit'); };
function renderSettings() {
  const st = S.settings;
  seg($('#setTheme'), st.theme || 'light', 'v'); seg($('#setSize'), st.tradeSize || 100, 'v'); seg($('#mSize'), st.tradeSize || 100, 'p');
  $$('#t-settings [data-s]').forEach(el => { const v = el.dataset.s.split('.').reduce((a, p) => a == null ? a : a[p], st); el.checked = !!v; });
  if (document.activeElement !== $('#shareUrl')) $('#shareUrl').value = (st.share && st.share.url) || '';
  $('#shareMsg').textContent = S.share.on ? S.share.msg : 'Off';
  $('#gameDir').textContent = S.gameDir || ''; $('#dataDir').textContent = S.dataDir || '';
}
if (sp.platform !== 'win32') { const sw = $('[data-s=startWithWindows]').closest('.field'); sw.querySelector('b').textContent = sp.platform === 'darwin' ? 'Open at login' : 'Start when I log in'; sw.querySelector('small').textContent = sp.platform === 'darwin' ? 'Starts quietly in the menu bar' : 'Starts quietly in the tray'; }
sp.call('version').then(v => { $('#aboutVer').textContent = 'StockPilot ' + v.app; $('#aboutSub').textContent = `Electron ${v.electron} · ${v.platform} ${v.arch}`; }).catch(() => { });

/* ---------------- main render */
function redrawCharts() { cards.forEach(k => { k.sig = ''; }); if (S) renderMarket(); drawDetail(); drawCompare(); drawNw(); if (S && tab === 'compare') renderCompareLegend(); }
let resizeT = null; window.addEventListener('resize', () => { clearTimeout(resizeT); resizeT = setTimeout(redrawCharts, 120); });
function render() {
  if (!S) return;
  applyTheme(S.settings.theme);
  renderHeader();
  if (tab === 'market') renderMarket();
  else if (tab === 'portfolio') renderPortfolio();
  else if (tab === 'news') renderNewsLive();
  else if (tab === 'auto') { renderAuto(); renderLog($('#aLog'), S.log.filter(l => /auto|practice|live|mode/i.test(l.msg))); }
  else if (tab === 'bot') renderBot();
  else if (tab === 'settings') renderSettings();
  else if (tab === 'journal' && jSub === 'activity') renderLog($('#jLog'), S.log);
  else if (tab === 'dividends') renderDividends();
  if (md.sid) renderDetailInfo();
}
function onState(s) {
  const first = !S; S = s; offMs = s.srvNow - Date.now();
  if (first) { rules = JSON.parse(JSON.stringify(s.auto.rules)); rulesVer = -1; renderAuto(); renderSettings(); }
  render();
}
sp.on('state', onState);
sp.call('state').then(s => { onState(s); showTab(store.get('tab', 'market')); }).catch(() => { });
setInterval(() => { if (S && tab === 'news') renderNewsLive(); }, 1000);
