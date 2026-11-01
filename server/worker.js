// StockPilot shared price server - speaks the protocol built into StockPilot 1.1 (Cloudflare Worker + D1 binding "DB")
// POST /v1/upload  text: "v1 <playerId>\n<minuteMs> $SID:p0,p1,...,p59;$SID2:...\n..."  (one line per minute, 60 one-second slots)
// GET  /v1/status  -> "v1 <serverNowMs> <latestSharedMinuteMs>"
// GET  /v1/range?from=<ms>&to=<ms>  -> "v1\n<minuteMs> <data>\n..."  (one line per player per minute; StockPilot takes the median)

const KEEP_DAYS = 8;            // StockPilot looks back 7 days
const COPIES = 3;               // players kept per minute
const MAX_LINES = 20;           // StockPilot sends up to 15 per request
const MAX_BODY = 600000;
const MAX_DATA = 60000;
const MAX_RANGE = 6 * 3600000;
const DATA_RE = /^(r\d{1,2}\|)?\$[A-Za-z0-9_]{1,16}:[0-9.eE+\-,]*(;\$[A-Za-z0-9_]{1,16}:[0-9.eE+\-,]*)*$/;
let ready = false;

function text(body, status = 200) {
  return new Response(body, {
    status,
    headers: { "Content-Type": "text/plain; charset=utf-8", "Access-Control-Allow-Origin": "*", "Cache-Control": "no-store" },
  });
}

async function init(db) {
  if (ready) return;
  await db.exec("CREATE TABLE IF NOT EXISTS mins (m INTEGER NOT NULL, u TEXT NOT NULL, d TEXT NOT NULL, PRIMARY KEY (m, u)) WITHOUT ROWID");
  ready = true;
}

async function upload(req, env, ctx, now) {
  const len = Number(req.headers.get("Content-Length") || 0);
  if (len > MAX_BODY) return text("too large", 413);
  let body = await req.text();
  if (body.length > MAX_BODY) return text("too large", 413);
  if (body.charCodeAt(0) === 0xfeff) body = body.slice(1);
  const lines = body.split("\n").map((l) => l.replace(/\r$/, "")).filter((l) => l.length);
  const head = (lines.shift() || "").split(" ");
  if (head[0] !== "v1" || !/^[A-Za-z0-9-]{8,64}$/.test(head[1] || "")) return text("bad header", 400);
  if (lines.length > MAX_LINES) return text("too many lines", 413);
  const user = head[1];
  const oldest = now - KEEP_DAYS * 86400000;
  const stmts = [];
  for (const line of lines) {
    const sp = line.indexOf(" ");
    if (sp < 1) continue;
    const m = Number(line.slice(0, sp));
    const d = line.slice(sp + 1);
    if (!Number.isSafeInteger(m) || m % 60000 !== 0 || m < oldest || m > now + 120000) continue;
    if (d.length > MAX_DATA || !DATA_RE.test(d)) continue;
    stmts.push(env.DB.prepare(
      "INSERT INTO mins (m, u, d) SELECT ?1, ?2, ?3 WHERE (SELECT COUNT(*) FROM mins WHERE m = ?1 AND u <> ?2) < ?4 ON CONFLICT (m, u) DO UPDATE SET d = excluded.d"
    ).bind(m, user, d, COPIES));
  }
  if (stmts.length) await env.DB.batch(stmts);
  if (Math.random() < 0.02) ctx.waitUntil(env.DB.prepare("DELETE FROM mins WHERE m < ?1").bind(oldest).run());
  return text("ok " + stmts.length + "/" + lines.length);
}

export default {
  async fetch(req, env, ctx) {
    const url = new URL(req.url);
    const now = Date.now();
    if (url.pathname === "/") return text("StockPilot shared price server");
    try {
      if (url.pathname === "/v1/upload") {
        if (req.method !== "POST") return text("use POST", 405);
        await init(env.DB);
        return await upload(req, env, ctx, now);
      }
      if (url.pathname === "/v1/status") {
        await init(env.DB);
        const r = await env.DB.prepare("SELECT MAX(m) AS m FROM mins").first();
        return text("v1 " + now + " " + ((r && r.m) || 0));
      }
      if (url.pathname === "/v1/range") {
        const from = Number(url.searchParams.get("from"));
        let to = Number(url.searchParams.get("to"));
        if (!Number.isFinite(from) || !Number.isFinite(to) || to <= from) return text("bad range", 400);
        if (to - from > MAX_RANGE) to = from + MAX_RANGE;
        await init(env.DB);
        const { results } = await env.DB.prepare("SELECT m, d FROM mins WHERE m >= ?1 AND m < ?2 ORDER BY m LIMIT 2000").bind(Math.floor(from), Math.ceil(to)).all();
        let out = "v1\n";
        for (const r of results) out += r.m + " " + r.d + "\n";
        return text(out);
      }
    } catch (e) {
      return text("server error: " + (e && e.message ? e.message : e), 500);
    }
    return text("not found", 404);
  },
};
