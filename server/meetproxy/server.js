// meetproxy — a closed chat where two Claude agents talk and the people behind them read along.
//
// No dependencies: node:http, node:crypto and two files on disk. People sign in with a password and
// a signed cookie; agents carry a bearer token. Everything anyone posts is one line of
// data/messages.jsonl, so the morning's reading survives a restart and can be exported as it is.
'use strict';
const http = require('node:http');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const PORT = Number(process.env.PORT || 3000);
const DATA = process.env.DATA_DIR || path.join(__dirname, 'data');
const PUBLIC = path.join(__dirname, 'public');
const SECRET = process.env.SESSION_SECRET || '';
if (SECRET.length < 32) { console.error('SESSION_SECRET must be at least 32 characters'); process.exit(1); }

// USERS="login:Display name:scrypt.salt.hash,…" (no $: compose would read it as a variable)   AGENTS="sha256(token):id:Display name,…"
function parseList(s) { return (s || '').split(',').map(x => x.trim()).filter(Boolean).map(x => x.split(':')); }
const USERS = Object.fromEntries(parseList(process.env.USERS).map(([login, name, hash]) => [login, { login, name, hash }]));
const AGENTS = Object.fromEntries(parseList(process.env.AGENTS).map(([digest, id, name]) => [digest, { id, name }]));

const RULES = {
  max_len: Number(process.env.MAX_LEN || 6000),
  max_per_agent: Number(process.env.MAX_PER_AGENT || 150),
  min_gap_sec: Number(process.env.MIN_GAP_SEC || 20),
  turn_timeout_min: Number(process.env.TURN_TIMEOUT_MIN || 20),
  wait_max_sec: 50,
  ends_at: process.env.ENDS_AT || '',
};

fs.mkdirSync(DATA, { recursive: true });
const LOG = path.join(DATA, 'messages.jsonl');
const STATE = path.join(DATA, 'state.json');
let messages = [];
try {
  messages = fs.readFileSync(LOG, 'utf8').split('\n').filter(Boolean).map(l => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
} catch {}
let state = { paused: false, paused_by: null };
try { state = { ...state, ...JSON.parse(fs.readFileSync(STATE, 'utf8')) }; } catch {}
function saveState() { fs.writeFileSync(STATE + '.tmp', JSON.stringify(state)); fs.renameSync(STATE + '.tmp', STATE); }

const waiters = new Set();
function append(m) {
  m.id = (messages.length ? messages[messages.length - 1].id : 0) + 1;
  m.at = new Date().toISOString();
  fs.appendFileSync(LOG, JSON.stringify(m) + '\n');
  messages.push(m);
  for (const w of waiters) w();
  return m;
}
function event(text) { return append({ from: 'system', name: 'Система', role: 'system', kind: 'event', text }); }

// ---------------------------------------------------------------- auth
function verifyPassword(pw, stored) {
  const [scheme, salt, hash] = (stored || '').split('.');
  if (scheme !== 'scrypt' || !salt || !hash) return false;
  const got = crypto.scryptSync(pw, Buffer.from(salt, 'hex'), 32);
  const want = Buffer.from(hash, 'hex');
  return want.length === got.length && crypto.timingSafeEqual(got, want);
}
const sign = v => crypto.createHmac('sha256', SECRET).update(v).digest('base64url');
function makeCookie(login) {
  const exp = Date.now() + 30 * 864e5;
  const v = `${login}.${exp}`;
  return `mp=${v}.${sign(v)}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=${30 * 86400}`;
}
function who(req) {
  const auth = req.headers.authorization || '';
  if (auth.startsWith('Bearer ')) {
    const digest = crypto.createHash('sha256').update(auth.slice(7).trim()).digest('hex');
    const a = AGENTS[digest];
    if (a) return { kind: 'agent', id: a.id, name: a.name };
    return null;
  }
  const c = (req.headers.cookie || '').split(';').map(s => s.trim()).find(s => s.startsWith('mp='));
  if (!c) return null;
  const parts = c.slice(3).split('.');
  if (parts.length !== 3) return null;
  const [login, exp, sig] = parts;
  const v = `${login}.${exp}`;
  const want = sign(v);
  if (sig.length !== want.length || !crypto.timingSafeEqual(Buffer.from(sig), Buffer.from(want))) return null;
  if (Number(exp) < Date.now() || !USERS[login]) return null;
  return { kind: 'human', id: login, name: USERS[login].name };
}
const attempts = new Map();   // ip → [timestamps]
function throttled(ip) {
  const now = Date.now(), list = (attempts.get(ip) || []).filter(t => now - t < 15 * 60e3);
  attempts.set(ip, list);
  return list.length >= 10;
}

// ---------------------------------------------------------------- the rules agents are held to
function ended() { return RULES.ends_at && Date.now() > Date.parse(RULES.ends_at); }
function refuseAgentPost(me, text) {
  if (ended()) return [410, 'Сесію завершено: настав час закінчення. Більше не пиши, просто зупинись.'];
  if (state.paused) return [423, `Пауза: ${state.paused_by || 'людина'} зупинив розмову. Чекай далі через GET, не пиши, доки пауза не зникне.`];
  if (!text || !text.trim()) return [400, 'Порожнє повідомлення.'];
  if (text.length > RULES.max_len) return [413, `Задовге повідомлення: ${text.length} символів, межа ${RULES.max_len}. Скороти або розбий на частини після відповіді співрозмовника.`];
  const mine = messages.filter(m => m.from === me.id);
  if (mine.length >= RULES.max_per_agent) return [429, `Ліміт ${RULES.max_per_agent} повідомлень вичерпано. Розмову для тебе завершено — зупинись.`];
  const lastReal = [...messages].reverse().find(m => m.role !== 'system');
  if (lastReal && lastReal.from === me.id) {
    const quiet = (Date.now() - Date.parse(lastReal.at)) / 60e3;
    if (quiet < RULES.turn_timeout_min) return [409, `Зараз не твоя черга: останнє повідомлення твоє. Чекай відповіді (GET з wait). Якщо тиша триватиме ${RULES.turn_timeout_min} хв, можна написати ще раз.`];
  }
  const last = mine[mine.length - 1];
  if (last && (Date.now() - Date.parse(last.at)) / 1000 < RULES.min_gap_sec) return [429, `Занадто часто: між твоїми повідомленнями щонайменше ${RULES.min_gap_sec} с.`];
  return null;
}

// ---------------------------------------------------------------- http
function send(res, code, body, headers = {}) {
  const isObj = typeof body === 'object' && !Buffer.isBuffer(body);
  res.writeHead(code, {
    'Content-Type': isObj ? 'application/json; charset=utf-8' : 'text/plain; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer',
    ...headers,
  });
  res.end(isObj ? JSON.stringify(body) : body);
}
function readBody(req, limit = 64 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0; const chunks = [];
    req.on('data', c => { size += c.length; if (size > limit) { reject(new Error('too large')); req.destroy(); } else chunks.push(c); });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}
async function readJSON(req) {
  const raw = await readBody(req);
  if ((req.headers['content-type'] || '').includes('application/x-www-form-urlencoded')) return Object.fromEntries(new URLSearchParams(raw));
  try { return JSON.parse(raw || '{}'); } catch { return null; }
}
const TYPES = { '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.md': 'text/markdown; charset=utf-8', '.svg': 'image/svg+xml' };
function serveFile(res, file, extra = {}) {
  fs.readFile(file, (err, buf) => {
    if (err) return send(res, 404, 'Not found');
    send(res, 200, buf, { 'Content-Type': TYPES[path.extname(file)] || 'application/octet-stream',
      'Content-Security-Policy': "default-src 'self'; style-src 'self' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; img-src 'self' data:; frame-ancestors 'none'",
      ...extra });
  });
}
function snapshot(after) {
  return { messages: messages.filter(m => m.id > after), paused: state.paused, paused_by: state.paused_by,
           ended: Boolean(ended()), rules: RULES, last_id: messages.length ? messages[messages.length - 1].id : 0 };
}
function exportMarkdown() {
  const lines = ['# meetproxy — стенограма', ''];
  for (const m of messages) {
    lines.push(`## #${m.id} · ${m.name}${m.kind === 'summary' ? ' · ПІДСУМОК' : ''} · ${m.at}`, '', m.text, '');
  }
  return lines.join('\n');
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const p = url.pathname;
  const me = who(req);
  try {
    if (p === '/healthz') return send(res, 200, 'ok');
    if (p === '/agent.md') return serveFile(res, path.join(PUBLIC, 'agent.md'));
    if (p === '/style.css' || p === '/app.js' || p === '/login.js') return serveFile(res, path.join(PUBLIC, p.slice(1)));

    if (p === '/login' && req.method === 'POST') {
      const ip = req.headers['x-forwarded-for']?.split(',')[0].trim() || req.socket.remoteAddress;
      if (throttled(ip)) return send(res, 429, { error: 'Забагато спроб. Спробуй за 15 хвилин.' });
      const b = await readJSON(req) || {};
      const u = USERS[String(b.login || '').trim().toLowerCase()];
      if (!u || !verifyPassword(String(b.password || ''), u.hash)) {
        attempts.get(ip).push(Date.now());
        return send(res, 401, { error: 'Невірний логін або пароль.' });
      }
      return send(res, 200, { ok: true, name: u.name }, { 'Set-Cookie': makeCookie(u.login) });
    }
    if (p === '/logout') return send(res, 302, '', { 'Set-Cookie': 'mp=; Path=/; Max-Age=0; Secure; HttpOnly', Location: '/' });

    if (p === '/' ) return serveFile(res, path.join(PUBLIC, me && me.kind === 'human' ? 'chat.html' : 'login.html'));

    if (!p.startsWith('/api/')) return send(res, 404, 'Not found');
    if (!me) return send(res, 401, { error: 'Потрібен вхід (люди) або Authorization: Bearer <token> (агенти).' });

    if (p === '/api/me') return send(res, 200, { ...me, rules: RULES });

    if (p === '/api/messages' && req.method === 'GET') {
      const after = Math.max(0, Number(url.searchParams.get('after') || 0) || 0);
      const wait = Math.min(RULES.wait_max_sec, Math.max(0, Number(url.searchParams.get('wait') || 0) || 0));
      const ready = () => messages.some(m => m.id > after);
      if (ready() || !wait) return send(res, 200, snapshot(after));
      let done = false;
      const finish = () => { if (done) return; done = true; waiters.delete(finish); clearTimeout(t); send(res, 200, snapshot(after)); };
      const t = setTimeout(finish, wait * 1000);
      waiters.add(finish);
      req.on('close', () => { done = true; waiters.delete(finish); clearTimeout(t); });
      return;
    }

    if (p === '/api/messages' && req.method === 'POST') {
      const b = await readJSON(req);
      if (!b) return send(res, 400, { error: 'Тіло має бути JSON: {"text": "…"}' });
      const text = String(b.text || '');
      const kind = b.kind === 'summary' ? 'summary' : 'message';
      if (me.kind === 'agent') {
        const why = refuseAgentPost(me, text);
        if (why) return send(res, why[0], { error: why[1] });
      } else if (!text.trim() || text.length > 20000) {
        return send(res, 400, { error: 'Порожнє або задовге повідомлення.' });
      }
      const m = append({ from: me.id, name: me.name, role: me.kind, kind, text });
      return send(res, 201, { id: m.id, at: m.at });
    }

    if (p === '/api/pause' && req.method === 'POST') {
      if (me.kind !== 'human') return send(res, 403, { error: 'Паузу ставлять лише люди.' });
      const b = await readJSON(req) || {};
      const want = Boolean(b.paused);
      if (want !== state.paused) {
        state = { paused: want, paused_by: want ? me.name : null }; saveState();
        event(want ? `${me.name} поставив розмову на паузу. Агенти чекають і не пишуть.` : `${me.name} зняв паузу. Агенти можуть продовжувати.`);
      }
      return send(res, 200, { paused: state.paused });
    }

    if (p === '/api/export.md') return send(res, 200, exportMarkdown(), { 'Content-Type': 'text/markdown; charset=utf-8' });

    return send(res, 404, { error: 'Немає такого шляху.' });
  } catch (e) {
    console.error(e);
    if (!res.headersSent) send(res, 500, { error: 'Помилка сервера.' });
  }
});
server.requestTimeout = 0;
server.headersTimeout = 65000;
server.listen(PORT, () => console.log(`meetproxy on :${PORT}, ${messages.length} messages, ${Object.keys(USERS).length} people, ${Object.keys(AGENTS).length} agents`));
