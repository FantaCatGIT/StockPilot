'use strict';
// small shared helpers (no Electron imports here so the backend can be tested in plain Node)
const fs = require('fs');
const path = require('path');

function num(x) {
  if (x === null || x === undefined || x === '') return 0;
  if (typeof x === 'number') return isFinite(x) ? x : 0;
  const n = parseFloat(String(x));
  return isFinite(n) ? n : 0;
}
const norm = s => String(s == null ? '' : s).trim().replace(/^\$/, '').toUpperCase();
const safeName = s => String(s).replace(/[^A-Za-z0-9_\-]/g, '_');
const dayKey = (t = Date.now()) => {
  const d = new Date(t);
  return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
};

function readText(p) {
  // the game may be mid-write; tolerate a BOM
  let s = fs.readFileSync(p, 'utf8');
  if (s.charCodeAt(0) === 0xfeff) s = s.slice(1);
  return s;
}
function readJson(p, tries = 3) {
  for (let i = 0; i < tries; i++) {
    try { if (!fs.existsSync(p)) return null; return JSON.parse(readText(p)); } catch (e) { /* retry */ }
  }
  return null;
}
function writeJson(p, obj) {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  const tmp = p + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 2));
  fs.renameSync(tmp, p);
}
function mkdirp(p) { fs.mkdirSync(p, { recursive: true }); return p; }
function exists(p) { try { return fs.existsSync(p); } catch (e) { return false; } }

// binary search: index of last element with t <= x in ts[] (sorted), -1 if none
function lastAtOrBefore(ts, x) {
  let lo = 0, hi = ts.length - 1, ans = -1;
  while (lo <= hi) { const m = (lo + hi) >> 1; if (ts[m] <= x) { ans = m; lo = m + 1; } else hi = m - 1; }
  return ans;
}

// keep min/max per bucket so spikes survive downsampling
function downsample(pts, max) {
  if (pts.length <= max) return pts;
  const out = [], buckets = Math.max(1, Math.floor(max / 2)), n = pts.length, size = n / buckets;
  for (let b = 0; b < buckets; b++) {
    const s = Math.floor(b * size), e = Math.min(n, Math.floor((b + 1) * size));
    if (e <= s) continue;
    let mi = s, ma = s;
    for (let i = s + 1; i < e; i++) { const v = pts[i][1]; if (v < pts[mi][1]) mi = i; if (v > pts[ma][1]) ma = i; }
    if (mi < ma) { out.push(pts[mi], pts[ma]); } else if (ma < mi) { out.push(pts[ma], pts[mi]); } else out.push(pts[mi]);
  }
  const last = pts[n - 1]; if (out[out.length - 1][0] !== last[0]) out.push(last);
  return out;
}

module.exports = { num, norm, safeName, dayKey, readText, readJson, writeJson, mkdirp, exists, lastAtOrBefore, downsample };
