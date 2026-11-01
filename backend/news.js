'use strict';
// Game announcements. The developer posts every update on Steam and in the Discord #announcements
// channel; Steam's public news API carries the same posts, so StockPilot reads those (reading another
// server's Discord channel would need a bot added by that server's owner).
const STEAM_NEWS = 'https://api.steampowered.com/ISteamNews/GetNewsForApp/v2/?appid=4356780&count=30&maxlength=0&format=json';

function bbToText(s) {
  return String(s || '')
    .replace(/\[img\][\s\S]*?\[\/img\]/gi, '')
    .replace(/\{STEAM_CLAN_IMAGE\}[^\s"\]]*/g, '')
    .replace(/\[url=([^\]]+)\]([\s\S]*?)\[\/url\]/gi, '$2')
    .replace(/\[\*\]/g, '• ')
    .replace(/\[\/?(?:b|i|u|h1|h2|h3|list|olist|quote|p|code|strike|spoiler|table|tr|td|th|hr|noparse|previewyoutube[^\]]*)\]/gi, '')
    .replace(/\[[a-z]+=[^\]]*\]/gi, '')
    .replace(/<br\s*\/?>/gi, '\n').replace(/<[^>]+>/g, '')
    .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'")
    .replace(/\n{3,}/g, '\n\n').trim();
}

function parseSteam(json) {
  const items = (json && json.appnews && json.appnews.newsitems) || [];
  return items
    .filter(it => !it.feedname || /announcement|steam_community|steam_updates|patch/i.test(it.feedname) || it.feed_type === 1)
    .map(it => ({ id: String(it.gid), title: it.title || 'Update', url: it.url || '', author: it.author || '', date: (it.date || 0) * 1000, text: bbToText(it.contents).slice(0, 4000) }))
    .sort((a, b) => b.date - a.date);
}

class News {
  constructor({ fetchFn, log, onNew }) { this.fetch = fetchFn; this.log = log || (() => { }); this.onNew = onNew; this.items = []; this.err = ''; this.fetchedAt = 0; this.seen = null; this.busy = false; }
  async refresh() {
    if (this.busy || !this.fetch) return; this.busy = true;
    try {
      const r = await this.fetch(STEAM_NEWS); if (r.status !== 200) throw new Error('HTTP ' + r.status);
      const items = parseSteam(await r.json());
      const ids = new Set(items.map(i => i.id));
      if (this.seen) { for (const it of items) if (!this.seen.has(it.id) && this.onNew) this.onNew(it); }
      this.seen = ids; this.items = items; this.err = ''; this.fetchedAt = Date.now();
    } catch (e) { this.err = String(e.message || e); }
    finally { this.busy = false; }
  }
}

module.exports = { News, parseSteam, bbToText };
