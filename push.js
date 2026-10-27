// Maydan Al Hayy: real push notifications through Firebase Cloud Messaging (HTTP v1).
// Turned on by placing the Firebase service account key at ../firebase-key.json (or FIREBASE_KEY_FILE).
// The database announces every new event (cells taken, friend joined, season medal) with pg_notify('maydan_push');
// this module listens and sends a notification to that player's phones.
'use strict';
const crypto = require('crypto'), fs = require('fs'), path = require('path');
const { Client } = require('pg');

const KEY_FILE = process.env.FIREBASE_KEY_FILE || path.join(__dirname, '..', 'firebase-key.json');
const FCM_BASE = process.env.FCM_BASE || 'https://fcm.googleapis.com';
const QUIET_MS = 30 * 60e3;          // at most one notification of the same kind per player per 30 minutes

let key = null, access = { token: null, exp: 0 };
const last = new Map();

function cellsN(n) { return n === 1 ? 'خلية' : n === 2 ? 'خليتين' : (n >= 3 && n <= 10) ? n + ' خلايا' : n + ' خلية'; }
function message(e) {
  const who = e.actor || 'لاعب';
  if (e.kind === 'stolen') return { title: cellsN(e.amount) + ' راحت لـ' + who + ' 😤', body: 'ارجع الميدان واسترجعها قبل نهاية الأسبوع', go: 'map' };
  if (e.kind === 'invite_joined') return { title: who + ' دخل بدعوتك 🎉', body: 'أضفنا 100 نقطة لك وله. يلا تحدّوا بعض', go: 'league' };
  if (e.kind === 'season_award') return { title: 'مبروك! المركز ' + e.amount + ' في الموسم الماضي 🏅', body: e.amount <= 3 ? 'أضفنا ' + [300, 200, 100][e.amount - 1] + ' نقطة لرصيدك ووسام في حسابك' : 'حصلت وسام الموسم في حسابك', go: 'me' };
  return null;
}

async function accessToken() {
  if (access.token && Date.now() < access.exp - 60e3) return access.token;
  const now = Math.floor(Date.now() / 1000), b = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const unsigned = b({ alg: 'RS256', typ: 'JWT' }) + '.' + b({ iss: key.client_email, scope: 'https://www.googleapis.com/auth/firebase.messaging', aud: key.token_uri, iat: now, exp: now + 3600 });
  const jwt = unsigned + '.' + crypto.sign('RSA-SHA256', Buffer.from(unsigned), key.private_key).toString('base64url');
  const r = await fetch(key.token_uri, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: 'grant_type=' + encodeURIComponent('urn:ietf:params:oauth:grant-type:jwt-bearer') + '&assertion=' + jwt });
  const j = await r.json();
  if (!j.access_token) throw new Error('firebase auth failed: ' + JSON.stringify(j).slice(0, 200));
  access = { token: j.access_token, exp: Date.now() + (j.expires_in || 3600) * 1000 };
  return access.token;
}

async function sendTo(pool, token, m, kind) {
  const r = await fetch(FCM_BASE + '/v1/projects/' + key.project_id + '/messages:send', {
    method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + await accessToken() },
    body: JSON.stringify({ message: { token, notification: { title: m.title, body: m.body }, data: { go: m.go, kind },
      android: { priority: 'HIGH', notification: { channel_id: 'maydan_alerts', icon: 'ic_tracking', color: '#8EE3C1', tag: kind, sound: 'default' } } } }),
  });
  if (r.ok) return true;
  const t = await r.text();
  if (r.status === 404 || /UNREGISTERED|INVALID_ARGUMENT.*registration/i.test(t)) await pool.query('select public.push_drop($1)', [token]).catch(() => {});
  else console.error(new Date().toISOString(), 'push failed', r.status, t.slice(0, 200));
  return false;
}

async function handle(pool, e) {
  const m = message(e); if (!m) return;
  const k = e.user_id + ':' + e.kind, now = Date.now();
  if (e.kind === 'stolen' && now - (last.get(k) || 0) < QUIET_MS) return;
  last.set(k, now);
  const r = await pool.query('select public.push_targets($1) as t', [e.user_id]);
  for (const row of r.rows) await sendTo(pool, row.t, m, e.kind).catch((err) => console.error('push', err.message));
}

function listen(pool, connectionString) {
  const c = new Client({ connectionString });
  const retry = () => { try { c.end(); } catch {} setTimeout(() => listen(pool, connectionString), 5000); };
  c.on('error', retry);
  c.on('notification', (n) => { try { handle(pool, JSON.parse(n.payload)).catch((err) => console.error('push', err.message)); } catch {} });
  c.connect().then(() => c.query('LISTEN maydan_push')).then(() => console.log('push notifications on (project ' + key.project_id + ')')).catch(retry);
}

module.exports = function start(pool, connectionString) {
  if (!fs.existsSync(KEY_FILE)) { console.log('push notifications off (no ' + KEY_FILE + ')'); return; }
  try { key = JSON.parse(fs.readFileSync(KEY_FILE, 'utf8')); } catch (e) { console.error('firebase key unreadable:', e.message); return; }
  if (!key.client_email || !key.private_key || !key.project_id) { console.error('firebase key incomplete'); return; }
  key.token_uri = key.token_uri || 'https://oauth2.googleapis.com/token';
  listen(pool, connectionString);
  setInterval(() => { const t = Date.now(); for (const [k, v] of last) if (t - v > QUIET_MS) last.delete(k); }, 10 * 60e3).unref();
};
