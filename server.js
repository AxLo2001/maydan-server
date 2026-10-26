// Maydan Al Hayy API server.
// Accounts (sign up / sign in / refresh / sign out) and the game calls (log_workout, claim, weekly_board,
// my_stats, cells_in_view, delete_my_account) run as SQL functions in PostgreSQL; this server only checks
// tokens and passes each call to the database as the signed-in user.
'use strict';
const http = require('http');
const crypto = require('crypto');
const { Pool } = require('pg');

const PORT = +process.env.PORT || 3000;
const SECRET = process.env.JWT_SECRET;
if (!SECRET || SECRET.length < 32) { console.error('JWT_SECRET missing or too short'); process.exit(1); }
const pool = new Pool({ connectionString: process.env.DATABASE_URL, max: 10 });
const ACCESS_TTL = 60 * 60;            // 1 hour
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
async function issue(userId) {
  const now = Math.floor(Date.now() / 1000);
  const access = signJwt({ sub: userId, iat: now, exp: now + ACCESS_TTL });
  const refresh = crypto.randomBytes(32).toString('base64url');
  await pool.query('insert into auth.refresh_tokens (token_hash, user_id, expires_at) values ($1, $2, now() + make_interval(secs => $3))', [sha(refresh), userId, REFRESH_TTL]);
  const u = await pool.query('select id, email, raw_user_meta_data as user_metadata from auth.users where id = $1', [userId]);
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
function limited(ip, max) {
  const now = Date.now(), w = hits.get(ip) || [];
  const recent = w.filter((t) => now - t < 60000); recent.push(now); hits.set(ip, recent);
  return recent.length > max;
}
setInterval(() => { const now = Date.now(); for (const [k, v] of hits) if (!v.some((t) => now - t < 60000)) hits.delete(k); }, 60000).unref();

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
};

const server = http.createServer(async (req, res) => {
  const ip = (req.headers['x-forwarded-for'] || req.socket.remoteAddress || '').split(',')[0].trim();
  const url = new URL(req.url, 'http://x');
  const path = url.pathname;
  if (req.method === 'OPTIONS') return send(res, 204, {});
  try {
    if (path === '/health') { await pool.query('select 1'); return send(res, 200, { ok: true }); }

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
      const rows = await asUser(uid, 'select client_id, started_at, mode, km::float8 as km, secs, pts, new_cells, steals from public.workouts order by started_at desc limit 20', []);
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
    if (/User already registered|Invalid login credentials/.test(m)) return send(res, 400, { error: m.match(/User already registered|Invalid login credentials/)[0] });
    if (/not signed in|bad workout|unknown|violates|invalid input/.test(m)) return send(res, 400, { error: m });
    console.error(new Date().toISOString(), path, m);
    return send(res, 500, { error: 'Server error' });
  }
});
server.listen(PORT, '127.0.0.1', () => console.log('Maydan API listening on 127.0.0.1:' + PORT));
setInterval(() => pool.query('delete from auth.refresh_tokens where expires_at < now()').catch(() => {}), 6 * 3600e3).unref();
