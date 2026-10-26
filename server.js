// Maydan Al Hayy API server.
// Accounts (sign up / sign in / refresh / sign out) and the game calls (log_workout, claim, weekly_board,
// my_stats, cells_in_view, delete_my_account) run as SQL functions in PostgreSQL; this server only checks
// tokens and passes each call to the database as the signed-in user.
'use strict';
const http = require('http');
const crypto = require('crypto');
const { Pool } = require('pg');

// optional settings file (used on Windows): KEY=VALUE lines in ../maydan.env or ENV_FILE
(() => {
  const fs = require('fs'), path = require('path');
  const f = process.env.ENV_FILE || path.join(__dirname, '..', 'maydan.env');
  if (!fs.existsSync(f)) return;
  for (const line of fs.readFileSync(f, 'utf8').split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$/);
    if (m && process.env[m[1]] === undefined) process.env[m[1]] = m[2];
  }
})();
const PORT = +process.env.PORT || 3000;
const SECRET = process.env.JWT_SECRET;
if (!SECRET || SECRET.length < 32) { console.error('JWT_SECRET missing or too short'); process.exit(1); }
const pool = new Pool({ connectionString: process.env.DATABASE_URL, max: 10 });
const ACCESS_TTL = 60 * 60;            // 1 hour
// Google sign-in: the OAuth "Web client ID" (or several, comma separated). Empty = Google sign-in switched off.
const GOOGLE_IDS = String(process.env.GOOGLE_CLIENT_IDS || process.env.GOOGLE_CLIENT_ID || '').split(',').map((x) => x.trim()).filter(Boolean);
const GOOGLE_CERTS = process.env.GOOGLE_CERTS_URL || 'https://www.googleapis.com/oauth2/v3/certs';
const REFRESH_TTL = 60 * 24 * 3600;    // 60 days

/* ---------- tokens (HS256 JWT) ---------- */
const b64u = (b) => Buffer.from(b).toString('base64url');
function signJwt(payload) {
  const h = b64u(JSON.stringify({ alg: 'HS256', typ: 'JWT' })), p = b64u(JSON.stringify(payload));
  return h + '.' + p + '.' + crypto.createHmac('sha256', SECRET).update(h + '.' + p).digest('base64url');
}
function verifyJwt(t) {
  const parts = String(t || '').split('.');
  if (parts.length !== 3) return null;
  const sig = crypto.createHmac('sha256', SECRET).update(parts[0] + '.' + parts[1]).digest();
  const got = Buffer.from(parts[2], 'base64url');
  if (got.length !== sig.length || !crypto.timingSafeEqual(got, sig)) return null;
  try { const p = JSON.parse(Buffer.from(parts[1], 'base64url')); return p.exp > Date.now() / 1000 ? p : null; } catch { return null; }
}
const sha = (s) => crypto.createHash('sha256').update(s).digest('hex');

/* ---------- Google ID tokens (RS256, checked against Google's published keys) ---------- */
let gKeys = { at: 0, ttl: 0, keys: {} };
async function googleKeys(force) {
  if (!force && Date.now() - gKeys.at < gKeys.ttl) return gKeys.keys;
  const r = await fetch(GOOGLE_CERTS);
  if (!r.ok) throw new Error('google keys ' + r.status);
  const age = +((r.headers.get('cache-control') || '').match(/max-age=(\d+)/) || [])[1] || 3600;
  const keys = {};
  for (const k of (await r.json()).keys || []) keys[k.kid] = crypto.createPublicKey({ key: k, format: 'jwk' });
  gKeys = { at: Date.now(), ttl: Math.min(age, 24 * 3600) * 1000, keys };
  return keys;
}
async function verifyGoogle(idToken) {
  if (!GOOGLE_IDS.length) throw new Error('google_off');
  const parts = String(idToken || '').split('.');
  if (parts.length !== 3) throw new Error('google_bad');
  let h, p;
  try { h = JSON.parse(Buffer.from(parts[0], 'base64url')); p = JSON.parse(Buffer.from(parts[1], 'base64url')); } catch { throw new Error('google_bad'); }
  if (h.alg !== 'RS256') throw new Error('google_bad');
  let key = (await googleKeys())[h.kid];
  if (!key) key = (await googleKeys(true))[h.kid];          // Google rotates keys now and then
  if (!key) throw new Error('google_bad');
  const ok = crypto.verify('RSA-SHA256', Buffer.from(parts[0] + '.' + parts[1]), key, Buffer.from(parts[2], 'base64url'));
  const now = Date.now() / 1000;
  if (!ok || !['accounts.google.com', 'https://accounts.google.com'].includes(p.iss) || !GOOGLE_IDS.includes(p.aud)
      || !(p.exp > now - 60) || !p.sub || !p.email || !(p.email_verified === true || p.email_verified === 'true')) throw new Error('google_bad');
  return { sub: String(p.sub), email: String(p.email).toLowerCase(), name: String(p.name || p.given_name || p.email.split('@')[0]).trim().slice(0, 20) };
}
const GUEST_NAMES = ['عدّاء', 'ماشي', 'رحّال', 'نشيط', 'سبّاق'];
const guestName = () => GUEST_NAMES[crypto.randomInt(GUEST_NAMES.length)] + ' ' + crypto.randomInt(1000, 10000);
async function issue(userId) {
  const now = Math.floor(Date.now() / 1000);
  const access = signJwt({ sub: userId, iat: now, exp: now + ACCESS_TTL });
  const refresh = crypto.randomBytes(32).toString('base64url');
  await pool.query('insert into auth.refresh_tokens (token_hash, user_id, expires_at) values ($1, $2, now() + make_interval(secs => $3))', [sha(refresh), userId, REFRESH_TTL]);
  const u = await pool.query("select id, case when is_guest then '' else email end as email, raw_user_meta_data as user_metadata, is_guest, google_sub is not null as google from auth.users where id = $1", [userId]);
  return { access_token: access, refresh_token: refresh, expires_at: now + ACCESS_TTL, user: u.rows[0] };
}

/* ---------- run SQL as the signed-in user ---------- */
async function asUser(uid, sql, args) {
  const c = await pool.connect();
  try {
    await c.query('begin');
    await c.query('set local role authenticated');
    await c.query("select set_config('request.jwt.claim.sub', $1, true)", [uid]);
    const r = await c.query(sql, args);
    await c.query('commit');
    return r.rows;
  } catch (e) { await c.query('rollback').catch(() => {}); throw e; }
  finally { c.release(); }
}

/* ---------- simple per-IP rate limit for account endpoints ---------- */
const hits = new Map();
function limited(ip, max, win = 60000) {
  const now = Date.now(), w = hits.get(ip) || [];
  const recent = w.filter((t) => now - t < win); recent.push(now); hits.set(ip, recent);
  return recent.length > max;
}
setInterval(() => { const now = Date.now(); for (const [k, v] of hits) if (!v.some((t) => now - t < 3600e3)) hits.delete(k); }, 60000).unref();

/* ---------- http ---------- */
function send(res, code, obj) {
  const b = JSON.stringify(obj);
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'Authorization, Content-Type', 'Access-Control-Allow-Methods': 'GET, POST, PATCH, OPTIONS', 'Cache-Control': 'no-store' });
  res.end(b);
}
function body(req) {
  return new Promise((ok, bad) => {
    let s = ''; req.on('data', (d) => { s += d; if (s.length > 2e6) { bad(new Error('too large')); req.destroy(); } });
    req.on('end', () => { try { ok(s ? JSON.parse(s) : {}); } catch { bad(new Error('bad json')); } });
  });
}
const emailOk = (e) => typeof e === 'string' && /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(e.trim()) && e.length <= 200;

const RPC = {
  log_workout: { sql: 'select public.log_workout($1::jsonb) as v', args: (a) => [JSON.stringify(a.p || {})], one: true },
  claim: { sql: 'select public.claim($1) as v', args: (a) => [String(a.p_id || '')], one: true },
  my_stats: { sql: 'select public.my_stats() as v', args: () => [], one: true },
  weekly_board: { sql: 'select rank::int as rank, name, pts::int as pts, is_me from public.weekly_board()', args: () => [] },
  cells_in_view: { sql: 'select * from public.cells_in_view($1, $2, $3, $4)', args: (a) => [+a.s, +a.w, +a.n, +a.e] },
  delete_my_account: { sql: 'select public.delete_my_account()', args: () => [], none: true },
  redeem_invite: { sql: 'select public.redeem_invite($1) as v', args: (a) => [String(a.p_code || '').slice(0, 12)], one: true },
  my_events: { sql: 'select * from public.my_events()', args: () => [] },
};

/* ---------- invite landing page: https://<server>/i/CODE ---------- */
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
async function invitePage(res, code) {
  const r = await pool.query('select name from public.profiles where invite_code = $1', [code]);
  const name = r.rows[0] ? r.rows[0].name : null;
  const dl = process.env.DOWNLOAD_URL || '';
  const html = `<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>ميدان الحي</title><meta property="og:title" content="${name ? esc(name) + ' يتحداك في ميدان الحي' : 'ميدان الحي'}">
<meta property="og:description" content="امش واجر في حيك، واحتل شوارعه، ونافس جيرانك كل أسبوع.">
<style>body{margin:0;min-height:100vh;background:#0A0E10;color:#F2F6F4;font-family:system-ui,-apple-system,'Segoe UI',sans-serif;display:flex;align-items:center;justify-content:center;padding:24px;box-sizing:border-box}
.c{max-width:380px;width:100%;text-align:center;display:flex;flex-direction:column;gap:18px;align-items:center}
.logo{width:76px;height:76px;border-radius:22px;background:linear-gradient(150deg,#B6F3DA,#5FCFA4);color:#06110D;font-weight:800;font-size:34px;display:flex;align-items:center;justify-content:center}
h1{margin:0;font-size:28px;line-height:1.35}p{margin:0;color:#BCC8C5;line-height:1.7}
.code{font-size:30px;font-weight:800;letter-spacing:6px;background:#1A2327;border-radius:16px;padding:14px 22px;direction:ltr}
a.b{display:block;width:100%;height:54px;line-height:54px;border-radius:16px;font-weight:700;text-decoration:none;box-sizing:border-box}
.p{background:#8EE3C1;color:#06110D}.g{background:#1A2327;color:#F2F6F4}.s{font-size:13px;color:#8C9C9A}</style></head>
<body><main class="c"><div class="logo">حي</div>
<h1>${name ? esc(name) + ' يتحداك في<br>ميدان الحي' : 'ميدان الحي'}</h1>
<p>امش واجر في حيك، واحتل شوارعه خلية خلية، ونافس جيرانك على صدارة الأسبوع.</p>
${name ? `<p class="s">كود الدعوة</p><div class="code">${esc(code)}</div><p class="s">اكتبه وقت التسجيل، وتاخذون أنت و${esc(name)} 100 نقطة أول ما تمشي كيلو.</p>` : '<p class="s">رابط الدعوة غير صحيح.</p>'}
<a class="b p" href="maydan://invite/${esc(code)}">افتح في التطبيق</a>
${dl ? `<a class="b g" href="${esc(dl)}">حمّل التطبيق</a>` : '<p class="s">التطبيق قريباً على Google Play.</p>'}
</main></body></html>`;
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(html);
}

const server = http.createServer(async (req, res) => {
  const ip = (req.headers['x-forwarded-for'] || req.socket.remoteAddress || '').split(',')[0].trim();
  const url = new URL(req.url, 'http://x');
  const path = url.pathname;
  if (req.method === 'OPTIONS') return send(res, 204, {});
  try {
    if (path === '/health') { await pool.query('select 1'); return send(res, 200, { ok: true }); }
    if (req.method === 'GET' && /^\/i\/[A-Za-z0-9]{4,12}$/.test(path)) return invitePage(res, path.slice(3).toUpperCase());

    /* accounts */
    if (path.startsWith('/auth/')) {
      if (req.method !== 'POST') return send(res, 405, { error: 'method' });
      if (limited(ip, path === '/auth/refresh' ? 60 : 12)) return send(res, 429, { error: 'Too many requests, rate limit' });
      const b = await body(req);
      if (path === '/auth/signup') {
        const name = String(b.name || '').trim().slice(0, 20);
        if (!emailOk(b.email)) return send(res, 400, { error: 'Unable to validate email address: invalid format' });
        if (typeof b.password !== 'string' || b.password.length < 8 || b.password.length > 72) return send(res, 400, { error: 'Password should be at least 8 characters' });
        if (name.length < 2) return send(res, 400, { error: 'Name too short' });
        const r = await pool.query('select auth.sign_up($1, $2, $3) as id', [b.email, b.password, name]);
        return send(res, 200, await issue(r.rows[0].id));
      }
      if (path === '/auth/login') {
        if (!emailOk(b.email) || typeof b.password !== 'string') return send(res, 400, { error: 'Invalid login credentials' });
        const r = await pool.query('select auth.sign_in($1, $2) as id', [b.email, b.password]);
        return send(res, 200, await issue(r.rows[0].id));
      }
      if (path === '/auth/guest') {
        if (limited('guest:' + ip, 10, 3600e3)) return send(res, 429, { error: 'Too many requests, rate limit' });
        const r = await pool.query('select auth.guest($1) as id', [guestName()]);
        return send(res, 200, await issue(r.rows[0].id));
      }
      if (path === '/auth/google') {
        const g = await verifyGoogle(b.id_token);
        const r = await pool.query('select auth.google($1, $2, $3) as v', [g.sub, g.email, g.name.length >= 2 ? g.name : 'لاعب']);
        return send(res, 200, Object.assign(await issue(r.rows[0].v.id), { created: r.rows[0].v.created }));
      }
      if (path === '/auth/upgrade') {
        const t = verifyJwt((req.headers.authorization || '').replace(/^Bearer\s+/i, ''));
        if (!t) return send(res, 401, { error: 'JWT expired or invalid' });
        if (b.id_token) {
          const g = await verifyGoogle(b.id_token);
          await pool.query('select auth.upgrade_google($1, $2, $3)', [t.sub, g.sub, g.email]);
        } else {
          if (!emailOk(b.email)) return send(res, 400, { error: 'Unable to validate email address: invalid format' });
          if (typeof b.password !== 'string' || b.password.length < 8 || b.password.length > 72) return send(res, 400, { error: 'Password should be at least 8 characters' });
          await pool.query('select auth.upgrade_email($1, $2, $3)', [t.sub, b.email, b.password]);
        }
        return send(res, 200, await issue(t.sub));
      }
      if (path === '/auth/refresh') {
        const h = sha(String(b.refresh_token || ''));
        const r = await pool.query('delete from auth.refresh_tokens where token_hash = $1 and expires_at > now() returning user_id', [h]);
        if (!r.rows.length) return send(res, 401, { error: 'Invalid refresh token' });
        return send(res, 200, await issue(r.rows[0].user_id));
      }
      if (path === '/auth/logout') {
        await pool.query('delete from auth.refresh_tokens where token_hash = $1', [sha(String(b.refresh_token || ''))]);
        return send(res, 200, { ok: true });
      }
      return send(res, 404, { error: 'not found' });
    }

    /* everything else needs a valid access token */
    const tok = verifyJwt((req.headers.authorization || '').replace(/^Bearer\s+/i, ''));
    if (!tok) return send(res, 401, { error: 'JWT expired or invalid' });
    const uid = tok.sub;

    if (path.startsWith('/rpc/') && req.method === 'POST') {
      const fn = RPC[path.slice(5)];
      if (!fn) return send(res, 404, { error: 'unknown function' });
      if (limited('rpc:' + uid, 120)) return send(res, 429, { error: 'Too many requests, rate limit' });
      const rows = await asUser(uid, fn.sql, fn.args(await body(req)));
      return send(res, 200, { data: fn.none ? null : fn.one ? rows[0].v : rows });
    }
    if (path === '/workouts' && req.method === 'GET') {
      const rows = await asUser(uid, 'select client_id, started_at, mode, km::float8 as km, secs, pts, new_cells, steals, steps, kcal from public.workouts order by started_at desc limit 20', []);
      return send(res, 200, { data: rows });
    }
    if (path === '/profile' && req.method === 'PATCH') {
      const b = await body(req); const name = String(b.name || '').trim();
      if (name.length < 2 || name.length > 20) return send(res, 400, { error: 'Name must be 2 to 20 characters' });
      await asUser(uid, 'update public.profiles set name = $1 where id = auth.uid()', [name]);
      return send(res, 200, { data: null });
    }
    return send(res, 404, { error: 'not found' });
  } catch (e) {
    const m = String(e.message || e);
    if (/User already registered|Invalid login credentials|google_taken|google_bad|google_off|not a guest/.test(m)) return send(res, 400, { error: m.match(/User already registered|Invalid login credentials|google_taken|google_bad|google_off|not a guest/)[0] });
    if (/not signed in|bad workout|unknown|violates|invalid input/.test(m)) return send(res, 400, { error: m });
    console.error(new Date().toISOString(), path, m);
    return send(res, 500, { error: 'Server error' });
  }
});
server.listen(PORT, '127.0.0.1', () => console.log('Maydan API listening on 127.0.0.1:' + PORT));
setInterval(() => {
  pool.query('delete from auth.refresh_tokens where expires_at < now()').catch(() => {});
  // guests who never trained and have not opened the app for 30 days
  pool.query('select auth.cleanup_guests()').catch(() => {});
}, 6 * 3600e3).unref();
