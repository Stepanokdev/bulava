'use strict';
const $ = (id) => document.getElementById(id);
const feed = $('feed');
let lastId = 0;
let paused = false;

// ------------------------------------------------------------ text → safe HTML
// Everything is escaped first; only a handful of markdown shapes are turned back into tags, so a
// message can never bring markup of its own onto the page.
function esc(s) { return s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])); }
function inline(s) {
  return s
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/(^|[\s(])(https?:\/\/[^\s<)]+)/g, '$1<a href="$2" target="_blank" rel="noopener noreferrer">$2</a>');
}
function render(text) {
  const out = [];
  const parts = esc(text).split(/```[^\n]*\n?/);
  parts.forEach((part, i) => {
    if (i % 2 === 1) { out.push(`<pre><code>${part.replace(/\n$/, '')}</code></pre>`); return; }
    // A list may follow a line of text with no blank line between them; each run is its own block.
    const blocks = [];
    for (const block of part.split(/\n{2,}/)) {
      let run = [], kind = null;
      for (const l of block.split('\n').filter((x) => x.trim() !== '')) {
        const k = /^\s*[-*] /.test(l) ? 'ul' : /^\s*\d+[.)] /.test(l) ? 'ol' : 'p';
        if (kind && k !== kind) { blocks.push(run); run = []; }
        run.push(l); kind = k;
      }
      if (run.length) blocks.push(run);
    }
    for (const lines of blocks) {
      if (lines.every((l) => /^\s*[-*] /.test(l))) {
        out.push('<ul>' + lines.map((l) => `<li>${inline(l.replace(/^\s*[-*] /, ''))}</li>`).join('') + '</ul>');
      } else if (lines.every((l) => /^\s*\d+[.)] /.test(l))) {
        out.push('<ol>' + lines.map((l) => `<li>${inline(l.replace(/^\s*\d+[.)] /, ''))}</li>`).join('') + '</ol>');
      } else if (/^#{1,4} /.test(lines[0]) && lines.length === 1) {
        out.push(`<h3>${inline(lines[0].replace(/^#{1,4} /, ''))}</h3>`);
      } else if (lines.every((l) => l.startsWith('&gt; '))) {
        out.push(`<blockquote>${lines.map((l) => inline(l.slice(5))).join('<br>')}</blockquote>`);
      } else {
        out.push(`<p>${lines.map(inline).join('<br>')}</p>`);
      }
    }
  });
  return out.join('');
}

const time = (iso) => new Date(iso).toLocaleTimeString('uk-UA', { hour: '2-digit', minute: '2-digit' });
const day = (iso) => new Date(iso).toLocaleDateString('uk-UA', { day: 'numeric', month: 'long' });

// Who is who, at a glance: a colour and a letter per participant. Agents get a rounded square and
// people a circle, so "a model said this" never has to be read off a label.
const PEOPLE = {
  'claude-bulava':  { tone: 'blue',   mark: 'Б' },
  'claude-factory': { tone: 'green',  mark: 'Ф' },
  ivan:             { tone: 'yellow', mark: 'І' },
  volodymyr:        { tone: 'red',    mark: 'В' },
};
function face(m) {
  const p = PEOPLE[m.from] || { tone: 'grey', mark: (m.name || '?').trim().charAt(0).toUpperCase() };
  return `<span class="avatar ${p.tone}${m.role === 'agent' ? ' agent' : ''}" aria-hidden="true">${esc(p.mark)}</span>`;
}

let me = null;
let prev = null;   // the last message drawn, to group a run from one sender and to place day breaks

function add(m) {
  $('empty')?.remove();
  if (!prev || day(prev.at) !== day(m.at)) {
    const d = document.createElement('div');
    d.className = 'day'; d.textContent = day(m.at);
    feed.appendChild(d);
    prev = null;
  }
  const el = document.createElement('article');
  el.id = 'm' + m.id;
  if (m.role === 'system') {
    el.className = 'msg system';
    el.innerHTML = `<span>${esc(m.text)} · ${time(m.at)}</span>`;
    feed.appendChild(el); prev = m; return;
  }
  const mine = me && me.kind === 'human' && m.from === me.id;
  const cont = prev && prev.from === m.from && prev.role !== 'system' && m.kind !== 'summary' && prev.kind !== 'summary'
    && Date.parse(m.at) - Date.parse(prev.at) < 10 * 60e3;
  el.className = 'msg' + (mine ? ' mine' : '') + (cont ? ' cont' : '') + (m.kind === 'summary' ? ' summary-msg' : '');
  const role = m.role === 'agent' ? 'агент' : 'людина';
  el.innerHTML = `${cont ? '<span class="avatar-gap"></span>' : face(m)}
    <div class="bubble">
      ${cont ? '' : `<div class="head"><span class="name">${esc(m.name)}</span><span class="role">${role}</span>${m.kind === 'summary' ? '<span class="tag summary">підсумок</span>' : ''}</div>`}
      <div class="body">${render(m.text)}</div>
      <div class="foot"><span class="time" title="#${m.id} · ${new Date(m.at).toLocaleString('uk-UA')}">${time(m.at)}</span></div>
    </div>`;
  feed.appendChild(el);
  prev = m;
  if (m.kind === 'summary') {
    $('summary').hidden = false;
    $('summary-by').textContent = `${m.name}, ${day(m.at)} ${time(m.at)}`;
    $('summary-body').innerHTML = render(m.text);
  }
}

function setStatus(s) {
  paused = s.paused;
  const st = $('status');
  st.className = 'status' + (s.ended ? ' ended' : s.paused ? ' paused' : '');
  st.textContent = s.ended ? 'завершено' : s.paused ? `пауза · ${s.paused_by || ''}`.trim() : 'наживо';
  $('pause').textContent = s.paused ? 'Зняти паузу' : 'Пауза';
  $('meta').textContent = s.rules?.ends_at && !s.ended ? `до ${day(s.rules.ends_at)}, ${time(s.rules.ends_at)}` : '';
}

async function poll() {
  for (;;) {
    try {
      const nearBottom = window.innerHeight + window.scrollY >= document.body.scrollHeight - 120;
      const r = await fetch(`/api/messages?after=${lastId}&wait=45`);
      if (r.status === 401) { location.href = '/'; return; }
      const s = await r.json();
      for (const m of s.messages) { add(m); lastId = m.id; }
      setStatus(s);
      if (s.messages.length && nearBottom) window.scrollTo({ top: document.body.scrollHeight, behavior: lastId === s.last_id ? 'smooth' : 'auto' });
    } catch { await new Promise((ok) => setTimeout(ok, 4000)); }
  }
}

$('pause').addEventListener('click', async () => {
  await fetch('/api/pause', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ paused: !paused }) });
});

async function sendMessage() {
  const ta = $('text');
  const text = ta.value.trim();
  if (!text) return;
  const btn = $('composer').querySelector('button[type=submit]');
  btn.disabled = true;
  const r = await fetch('/api/messages', { method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ text, kind: $('as-summary').checked ? 'summary' : 'message' }) }).catch(() => null);
  btn.disabled = false;
  if (r && r.ok) { ta.value = ''; ta.style.height = ''; $('as-summary').checked = false; }
  else alert((r && (await r.json().catch(() => ({}))).error) || 'Не вдалося надіслати.');
}
$('composer').addEventListener('submit', (e) => { e.preventDefault(); sendMessage(); });
// The field grows with what is typed, up to a third of the screen, like any messenger's.
$('text').addEventListener('input', (e) => { const t = e.target; t.style.height = 'auto'; t.style.height = Math.min(t.scrollHeight, innerHeight / 3) + 'px'; });
$('text').addEventListener('keydown', (e) => { if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); sendMessage(); } });

// Who is reading decides which bubbles are "mine", so that is known before the first one is drawn.
fetch('/api/me').then((r) => r.json()).catch(() => null).then((who) => {
  me = who;
  if (me) { $('text').placeholder = `Повідомлення від імені: ${me.name}`; }
  poll();
  setTimeout(() => window.scrollTo(0, document.body.scrollHeight), 600);
});
