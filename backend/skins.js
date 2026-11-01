'use strict';
// Screen Stocks skins: mods/skins/<name>.json + image. StockPilot's own are sp-<slug>.*
// Animated skins (GIF/video) keep their frames in <data>/anim/<base>/NNNN.jpg and copy the
// current frame over mods/skins/<base>.jpg while the game runs, so the skin loops.
const fs = require('fs');
const path = require('path');
const { readJson, mkdirp } = require('./util');

const NAME_RE = /^[A-Za-z0-9 _\-.!]{1,40}$/;
const VIS = [['BGLevel', false], ['BGMoney', true], ['CenterBG', false], ['DividendBG', true], ['GraphBG', true], ['InfoBG', false], ['MainBG', false], ['NewsBG', true], ['SharesBG', true], ['TickerBG', true]];

function buildJson(name, col, frames, glow, img) {
  const o = {
    enabled: true, displayName: name, backgroundImage: '', backgroundSprite: 3, uiImageColor: '#FFFFFF',
    cameraBackgroundColor: col.bg + 'FF', usesOSFrame: !!frames, osFrameColor: col.panels + 'EE',
    osFrames: VIS.map(([id, visible]) => ({ id, visible })),
    usesBloom: !!glow, bloomColor: col.glowColor, bloomIntensity: 1.5, bloomStrength: 2.0, bloomSpill: 0.0,
    usesSkinImage: true, skinImage: img, skinImageAspectRatio: { x: 0.0, y: 0.0 }, skinImageScale: 1.0,
    buttonSprite: -1, buttonColor: col.buttons + 'FF',
  };
  // the game's own files use 4-space JSON with x.0 floats
  return JSON.stringify(o, null, 4).replace(/"(bloomStrength|bloomSpill|skinImageScale|x|y)": (\d+)(,?)$/gm, '"$1": $2.0$3');
}

class Skins {
  constructor({ skinsDir, dataDir, log }) {
    this.dir = skinsDir; this.thumbs = path.join(dataDir, 'skin-thumbs'); this.animDir = path.join(dataDir, 'anim');
    this.log = log || (() => { }); this.anims = new Map();
  }
  slug(name) {
    name = String(name || '').trim();
    if (!NAME_RE.test(name)) throw new Error('Use 1-40 letters, numbers, spaces or - _ . ! for the name.');
    return { name, base: 'sp-' + (name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || 'skin') };
  }
  colors(meta) {
    const col = {};
    for (const k of ['panels', 'buttons', 'glowColor', 'bg']) { let v = String(meta[k] || ''); if (!/^#[0-9A-Fa-f]{6}$/.test(v)) v = '#2C2C35'; col[k] = v.toUpperCase(); }
    return col;
  }
  saveThumb(base, t) {
    if (typeof t === 'string' && t.startsWith('data:image/jpeg;base64,')) {
      try { const b = Buffer.from(t.slice(23), 'base64'); if (b.length < 600 * 1024) { mkdirp(this.thumbs); fs.writeFileSync(path.join(this.thumbs, base + '.jpg'), b); } } catch (e) { }
    }
  }
  list() {
    const out = [];
    let files = []; try { files = fs.readdirSync(this.dir).filter(f => f.endsWith('.json')).sort(); } catch (e) { return out; }
    for (const f of files) {
      const j = readJson(path.join(this.dir, f)); if (!j) continue;
      const base = f.slice(0, -5), ours = f.startsWith('sp-');
      let thumb = '';
      if (ours) { const tp = path.join(this.thumbs, base + '.jpg'); try { if (fs.existsSync(tp)) thumb = 'data:image/jpeg;base64,' + fs.readFileSync(tp).toString('base64'); } catch (e) { } }
      out.push({ file: f, name: j.displayName || base, enabled: j.enabled !== false, ours, anim: this.anims.has(base), thumb });
    }
    return out;
  }
  animRemove(base) {
    this.anims.delete(base);
    try { fs.rmSync(path.join(this.animDir, base), { recursive: true, force: true }); } catch (e) { }
  }
  addStatic(meta, b64) {
    const { name, base } = this.slug(meta.name);
    const bytes = Buffer.from(String(b64).trim(), 'base64');
    if (bytes.length < 8 || bytes[0] !== 0x89 || bytes[1] !== 0x50 || bytes[2] !== 0x4e || bytes[3] !== 0x47) throw new Error('The picture could not be converted.');
    if (bytes.length > 40 * 1024 * 1024) throw new Error('The picture is too big.');
    mkdirp(this.dir);
    this.animRemove(base);
    try { fs.unlinkSync(path.join(this.dir, base + '.jpg')); } catch (e) { }
    fs.writeFileSync(path.join(this.dir, base + '.png'), bytes);
    fs.writeFileSync(path.join(this.dir, base + '.json'), buildJson(name, this.colors(meta), meta.frames !== false, meta.glow === true, base + '.png'));
    this.saveThumb(base, meta.thumb);
    this.log(`Skin '${name}' added to the game.`, 'ok');
    return base + '.json';
  }
  animStart(meta) {
    const { name, base } = this.slug(meta.name);
    let fps = +meta.fps; if (!(fps > 0 && fps <= 30)) fps = 10;
    const count = parseInt(meta.count, 10); if (!(count >= 1 && count <= 400)) throw new Error('Too many frames.');
    mkdirp(this.dir);
    try { fs.unlinkSync(path.join(this.dir, base + '.png')); } catch (e) { }
    this.animRemove(base);
    const ad = mkdirp(path.join(this.animDir, base));
    fs.writeFileSync(path.join(this.dir, base + '.json'), buildJson(name, this.colors(meta), meta.frames !== false, meta.glow === true, base + '.jpg'));
    this.saveThumb(base, meta.thumb);
    fs.writeFileSync(path.join(ad, 'meta.json'), JSON.stringify({ fps, count }));
    this.anims.set(base, { dir: ad, count: 0, fps, idx: 0, nextAt: 0, enabled: true, img: path.join(this.dir, base + '.jpg'), ready: false });
    return base;
  }
  animFrame(base, idx, b64) {
    const a = this.anims.get(base); if (!a) throw new Error('Unknown skin.');
    idx = parseInt(idx, 10); if (!(idx >= 0 && idx <= 399)) throw new Error('bad frame');
    const bytes = Buffer.from(String(b64).trim(), 'base64');
    if (bytes.length < 3 || bytes[0] !== 0xff || bytes[1] !== 0xd8) throw new Error('bad frame');
    if (bytes.length > 8 * 1024 * 1024) throw new Error('frame too big');
    fs.writeFileSync(path.join(a.dir, String(idx).padStart(4, '0') + '.jpg'), bytes);
    if (idx === 0) { try { fs.writeFileSync(a.img, bytes); } catch (e) { } }
  }
  animFinish(base, count) {
    const a = this.anims.get(base); if (!a) throw new Error('Unknown skin.');
    const have = fs.readdirSync(a.dir).filter(f => f.endsWith('.jpg')).length;
    if (have < 1) throw new Error('No frames received.');
    a.count = Math.min(parseInt(count, 10) || have, have); a.ready = true; a.idx = 0; a.nextAt = 0;
    fs.writeFileSync(path.join(a.dir, 'meta.json'), JSON.stringify({ fps: a.fps, count: a.count }));
    try { fs.copyFileSync(path.join(a.dir, '0000.jpg'), a.img); } catch (e) { }
    this.log(`Animated skin added (${a.count} frames, loops while the game is open).`, 'ok');
  }
  setEnabled(file, on) {
    if (!/^[^\\/:*?"<>|]+\.json$/.test(file)) throw new Error('bad file');
    const p = path.join(this.dir, file); if (!fs.existsSync(p)) throw new Error('Skin not found.');
    const txt = fs.readFileSync(p, 'utf8');
    const nw = txt.replace(/("enabled"\s*:\s*)(true|false)/, '$1' + (on ? 'true' : 'false'));
    if (nw !== txt) fs.writeFileSync(p, nw);
    const a = this.anims.get(file.slice(0, -5)); if (a) a.enabled = !!on;
  }
  remove(file) {
    if (!/^sp-[a-z0-9\-]+\.json$/.test(file)) throw new Error('Only skins made with StockPilot can be deleted here.');
    const base = file.slice(0, -5);
    this.animRemove(base);
    for (const p of [path.join(this.dir, file), path.join(this.dir, base + '.png'), path.join(this.dir, base + '.jpg'), path.join(this.thumbs, base + '.jpg')]) { try { fs.unlinkSync(p); } catch (e) { } }
    this.log('Skin deleted.', 'info');
  }
  animLoad() {
    this.anims.clear();
    let dirs = []; try { dirs = fs.readdirSync(this.animDir, { withFileTypes: true }).filter(d => d.isDirectory()).map(d => d.name); } catch (e) { return; }
    for (const base of dirs) {
      const json = path.join(this.dir, base + '.json'); if (!fs.existsSync(json)) continue;
      const meta = readJson(path.join(this.animDir, base, 'meta.json')); if (!meta || !(meta.count >= 1)) continue;
      const j = readJson(json);
      this.anims.set(base, { dir: path.join(this.animDir, base), count: meta.count, fps: +meta.fps || 10, idx: 0, nextAt: 0, enabled: !(j && j.enabled === false), img: path.join(this.dir, base + '.jpg'), ready: true });
    }
  }
  animStep(connected) {
    if (!this.anims.size || !connected) return;
    const now = Date.now();
    for (const a of this.anims.values()) {
      if (!a.enabled || !a.ready || a.count < 2 || now < a.nextAt) continue;
      a.nextAt = now + Math.max(40, 1000 / a.fps);
      a.idx = (a.idx + 1) % a.count;
      try { fs.copyFileSync(path.join(a.dir, String(a.idx).padStart(4, '0') + '.jpg'), a.img); } catch (e) { }
    }
  }
}

module.exports = { Skins, buildJson };
