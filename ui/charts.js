'use strict';
// Small canvas charts: sparklines, the price chart (with avg-buy line, trade marks and a crosshair) and compare lines.
const Charts = (() => {
  const css = n => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
  function setup(cv) {
    const r = cv.getBoundingClientRect(), dpr = window.devicePixelRatio || 1;
    const w = Math.max(10, Math.round(r.width)), h = Math.max(10, Math.round(r.height));
    if (cv.width !== Math.round(w * dpr) || cv.height !== Math.round(h * dpr)) { cv.width = Math.round(w * dpr); cv.height = Math.round(h * dpr); }
    const x = cv.getContext('2d'); x.setTransform(dpr, 0, 0, dpr, 0, 0); x.clearRect(0, 0, w, h);
    return { x, w, h };
  }
  function alpha(col, a) {
    if (col.startsWith('#')) { let c = col.slice(1); if (c.length === 3) c = c.split('').map(z => z + z).join(''); const n = parseInt(c, 16); return `rgba(${n >> 16 & 255},${n >> 8 & 255},${n & 255},${a})`; }
    return col;
  }
  // values only; colour is the stock's own colour (no green/red)
  function spark(cv, vals, color, avg) {
    const { x, w, h } = setup(cv);
    if (!vals || vals.length < 2) { x.fillStyle = css('--faint'); x.font = '11px Segoe UI, sans-serif'; x.fillText('waiting for prices…', 8, h / 2 + 4); return; }
    let lo = Math.min(...vals), hi = Math.max(...vals);
    if (avg > 0 && avg > lo * 0.8 && avg < hi * 1.25) { lo = Math.min(lo, avg); hi = Math.max(hi, avg); }
    if (hi - lo < hi * 1e-9) { hi += Math.abs(hi) * 0.001 + 1e-9; lo -= Math.abs(lo) * 0.001 + 1e-9; }
    const pad = 5, X = i => i / (vals.length - 1) * w, Y = v => pad + (1 - (v - lo) / (hi - lo)) * (h - 2 * pad);
    const g = x.createLinearGradient(0, 0, 0, h); g.addColorStop(0, alpha(color, .22)); g.addColorStop(1, alpha(color, 0));
    x.beginPath(); x.moveTo(0, h); vals.forEach((v, i) => x.lineTo(X(i), Y(v))); x.lineTo(w, h); x.closePath(); x.fillStyle = g; x.fill();
    x.beginPath(); vals.forEach((v, i) => i ? x.lineTo(X(i), Y(v)) : x.moveTo(X(i), Y(v))); x.strokeStyle = color; x.lineWidth = 1.6; x.lineJoin = 'round'; x.stroke();
    if (avg > 0 && avg >= lo && avg <= hi) { x.setLineDash([4, 3]); x.strokeStyle = css('--muted'); x.lineWidth = 1; x.beginPath(); x.moveTo(0, Y(avg)); x.lineTo(w, Y(avg)); x.stroke(); x.setLineDash([]); }
    const lv = vals[vals.length - 1]; x.fillStyle = color; x.beginPath(); x.arc(w - 2.5, Y(lv), 2.5, 0, 7); x.fill();
  }
  function niceTicks(lo, hi, n) {
    const span = hi - lo; if (!(span > 0)) return [lo];
    const step0 = span / n, mag = Math.pow(10, Math.floor(Math.log10(step0))), f = step0 / mag;
    const step = (f < 1.5 ? 1 : f < 3 ? 2 : f < 7 ? 5 : 10) * mag, out = [];
    for (let v = Math.ceil(lo / step) * step; v <= hi + step * 1e-6; v += step) out.push(v);
    return out;
  }
  function timeFmt(t, span) {
    const d = new Date(t);
    if (span > 3 * 86400000) return d.toLocaleDateString([], { month: 'short', day: 'numeric' });
    if (span > 86400000) return d.toLocaleDateString([], { weekday: 'short' }) + ' ' + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    if (span > 600000) return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
  }
  // opts: { series:[{pts:[[t,v]], color, width, name}], from, to, yFmt, hlines:[{v,label,color}], marks:[{t,v,label,color,up}], hoverT }
  function line(cv, o) {
    const { x, w, h } = setup(cv);
    const L = 64, R = 12, T = 30, B = 26, pw = w - L - R, ph = h - T - B;
    const all = []; o.series.forEach(s => s.pts.forEach(p => { if (p[0] >= o.from && p[0] <= o.to) all.push(p[1]); }));
    (o.hlines || []).forEach(hl => { if (hl.always) all.push(hl.v); });
    x.font = '11px "Segoe UI", system-ui, sans-serif';
    if (!all.length) { x.fillStyle = css('--muted'); x.font = '13px "Segoe UI", sans-serif'; x.textAlign = 'center'; x.fillText(o.empty || 'No prices recorded for this time range yet.', w / 2, h / 2); cv._lay = null; return; }
    let lo = Math.min(...all), hi = Math.max(...all);
    if (hi - lo < Math.abs(hi) * 1e-6 + 1e-12) { const d = Math.abs(hi) * 0.002 + 1e-9; hi += d; lo -= d; }
    const padv = (hi - lo) * 0.08; hi += padv; lo -= padv;
    if (!o.signed && lo < 0 && Math.min(...all) >= 0) lo = 0;
    const X = t => L + (t - o.from) / Math.max(1, o.to - o.from) * pw, Y = v => T + (1 - (v - lo) / (hi - lo)) * ph;
    // grid + axes
    x.strokeStyle = css('--grid'); x.lineWidth = 1; x.fillStyle = css('--axis'); x.textAlign = 'right'; x.textBaseline = 'middle';
    for (const v of niceTicks(lo, hi, 5)) { const y = Math.round(Y(v)) + .5; x.beginPath(); x.moveTo(L, y); x.lineTo(w - R, y); x.stroke(); x.fillText(o.yFmt(v), L - 7, y); }
    x.textAlign = 'center'; x.textBaseline = 'top';
    const span = o.to - o.from, nx = Math.max(2, Math.floor(pw / 110));
    for (let i = 0; i <= nx; i++) { const t = o.from + span * i / nx, px = X(t); x.fillText(timeFmt(t, span), Math.min(w - R - 30, Math.max(L + 30, px)), h - B + 7); }
    if (o.zero) { x.strokeStyle = css('--axis'); x.setLineDash([2, 3]); x.beginPath(); x.moveTo(L, Y(0)); x.lineTo(w - R, Y(0)); x.stroke(); x.setLineDash([]); }
    x.save(); x.beginPath(); x.rect(L, T - 4, pw, ph + 8); x.clip();
    // lines
    for (const s of o.series) {
      const pts = s.pts; if (!pts.length) continue;
      if (o.series.length === 1) {
        const g = x.createLinearGradient(0, T, 0, T + ph); g.addColorStop(0, alpha(s.color, .18)); g.addColorStop(1, alpha(s.color, 0));
        // fill each continuous run separately so gaps (game closed) stay empty
        x.fillStyle = g; let st = 0;
        for (let i = 1; i <= pts.length; i++) {
          if (i < pts.length && !(pts[i][0] - pts[i - 1][0] > (o.gap || Infinity))) continue;
          x.beginPath(); x.moveTo(X(pts[st][0]), T + ph); for (let j = st; j < i; j++) x.lineTo(X(pts[j][0]), Y(pts[j][1])); x.lineTo(X(pts[i - 1][0]), T + ph); x.closePath(); x.fill(); st = i;
        }
      }
      x.beginPath(); let prevT = null;
      pts.forEach(p => { const px = X(p[0]), py = Y(p[1]); if (prevT === null || p[0] - prevT > (o.gap || Infinity)) x.moveTo(px, py); else x.lineTo(px, py); prevT = p[0]; });
      x.strokeStyle = s.color; x.lineWidth = s.width || 1.8; x.lineJoin = 'round'; x.stroke();
    }
    x.restore();
    for (const hl of o.hlines || []) {
      if (hl.v < lo || hl.v > hi) continue; const y = Math.round(Y(hl.v)) + .5;
      x.setLineDash([6, 4]); x.strokeStyle = hl.color || css('--muted'); x.lineWidth = 1.2; x.beginPath(); x.moveTo(L, y); x.lineTo(w - R, y); x.stroke(); x.setLineDash([]);
      x.font = '600 11px "Segoe UI", sans-serif'; const tw = x.measureText(hl.label).width + 10;
      x.fillStyle = hl.color || css('--muted'); x.fillRect(w - R - tw, y - 9, tw, 18); x.fillStyle = '#fff'; x.textAlign = 'center'; x.textBaseline = 'middle'; x.fillText(hl.label, w - R - tw / 2, y);
    }
    for (const m of o.marks || []) {
      if (m.t < o.from || m.t > o.to) continue; const px = X(m.t), py = Y(Math.max(lo, Math.min(hi, m.v)));
      x.fillStyle = m.color; x.beginPath();
      if (m.up) { x.moveTo(px, py - 1); x.lineTo(px - 6, py + 10); x.lineTo(px + 6, py + 10); } else { x.moveTo(px, py + 1); x.lineTo(px - 6, py - 10); x.lineTo(px + 6, py - 10); }
      x.closePath(); x.fill(); x.strokeStyle = css('--panel'); x.lineWidth = 1.2; x.stroke();
    }
    cv._lay = { L, R, T, B, pw, ph, X, Y, lo, hi, o, w, h };
    if (o.hoverX != null) crosshair(cv, x, o.hoverX);
  }
  function nearest(pts, t) {
    let a = 0, b = pts.length - 1; if (b < 0) return null;
    while (a < b) { const m = (a + b) >> 1; if (pts[m][0] < t) a = m + 1; else b = m; }
    if (a > 0 && Math.abs(pts[a - 1][0] - t) < Math.abs(pts[a][0] - t)) a--;
    return pts[a];
  }
  function crosshair(cv, x, mx) {
    const l = cv._lay; if (!l || mx < l.L || mx > l.w - l.R) return;
    const t = l.o.from + (mx - l.L) / l.pw * (l.o.to - l.o.from);
    x.strokeStyle = css('--axis'); x.lineWidth = 1; x.setLineDash([3, 3]); x.beginPath(); x.moveTo(mx + .5, l.T); x.lineTo(mx + .5, l.T + l.ph); x.stroke(); x.setLineDash([]);
    const parts = [];
    for (const s of l.o.series) { const p = nearest(s.pts, t); if (!p || Math.abs(p[0] - t) > (l.o.to - l.o.from) / 20) continue; x.fillStyle = s.color; x.beginPath(); x.arc(l.X(p[0]), l.Y(p[1]), 3.5, 0, 7); x.fill(); parts.push([s, p]); }
    if (!parts.length) return;
    x.font = '12px "Segoe UI", sans-serif'; x.textBaseline = 'middle'; x.textAlign = 'left';
    const lines = [timeFmt(parts[0][1][0], 1000)].concat(parts.slice(0, 8).map(([s, p]) => (s.name ? s.name + '  ' : '') + l.o.yFmt(p[1], true)));
    const bw = Math.max(...lines.map(s => x.measureText(s).width)) + 18, bh = lines.length * 17 + 8;
    let bx = mx + 12; if (bx + bw > l.w - l.R) bx = mx - 12 - bw; const by = l.T + 4;
    x.fillStyle = css('--panel'); x.strokeStyle = css('--line'); x.beginPath(); x.rect(bx, by, bw, bh); x.fill(); x.stroke();
    lines.forEach((s, i) => { x.fillStyle = i === 0 ? css('--muted') : (parts[i - 1][0].color); x.fillText(s, bx + 9, by + 12 + i * 17); });
  }
  // keep a crosshair on hover: re-draws using the last options
  function hover(cv, redraw) {
    cv.addEventListener('mousemove', e => { const r = cv.getBoundingClientRect(); redraw(e.clientX - r.left); });
    cv.addEventListener('mouseleave', () => redraw(null));
  }
  return { spark, line, hover, css, alpha };
})();
