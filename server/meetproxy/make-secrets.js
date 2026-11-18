// node make-secrets.js <out-dir> — writes <out-dir>/.env for the server and <out-dir>/credentials.txt
// for the people and the two agents. Run once; running again replaces every password and token.
const crypto = require('node:crypto'), fs = require('node:fs'), path = require('node:path');
const out = process.argv[2] || '.';
const pw = () => crypto.randomBytes(12).toString('base64url');
const hash = (p) => { const s = crypto.randomBytes(16); return `scrypt.${s.toString('hex')}.${crypto.scryptSync(p, s, 32).toString('hex')}`; };
// PEOPLE="login:Name,login:Name" names who signs in; the default is the author and one guest.
// The server lowercases the login typed at the door and splits its cookie on dots, and USERS is
// split on commas and colons. So a login is lowercase letters, digits, "_" and "-", a name holds
// no comma or colon, and each login appears once: anything else is refused before a file is written.
function readPeople(spec) {
  const seen = new Set();
  return spec.split(',').map((s) => s.trim()).filter(Boolean).map((entry) => {
    const i = entry.indexOf(':');
    const l = (i < 0 ? entry : entry.slice(0, i)).trim().toLowerCase();
    const n = (i < 0 ? '' : entry.slice(i + 1)).trim();
    if (!/^[a-z0-9_-]{1,32}$/.test(l)) throw new Error(`login «${l}»: only a-z, 0-9, "_" and "-", up to 32`);
    if (!n || /[,:]/.test(n)) throw new Error(`login «${l}»: a display name is required and holds no "," or ":"`);
    if (seen.has(l)) throw new Error(`login «${l}» appears twice`);
    seen.add(l);
    return { l, n, p: pw() };
  });
}
let people;
try {
  people = readPeople(process.env.PEOPLE || 'ivan:Іван,guest:Гість');
  if (!people.length) throw new Error('PEOPLE names nobody');
} catch (e) {
  console.error(`PEOPLE refused: ${e.message}. Nothing was written.`);
  process.exit(2);
}
const agents = [['claude-bulava', 'Claude · Bulava'], ['claude-factory', 'Claude · фабрика']].map(([id, n]) => ({ id, n, t: 'mp_' + crypto.randomBytes(24).toString('base64url') }));
const env = [
  `SESSION_SECRET=${crypto.randomBytes(32).toString('hex')}`,
  `USERS=${people.map((u) => `${u.l}:${u.n}:${hash(u.p)}`).join(',')}`,
  `AGENTS=${agents.map((a) => `${crypto.createHash('sha256').update(a.t).digest('hex')}:${a.id}:${a.n}`).join(',')}`,
  `ENDS_AT=${process.env.ENDS_AT || ''}`,
].join('\n') + '\n';
fs.writeFileSync(path.join(out, '.env'), env, { mode: 0o600 });
fs.writeFileSync(path.join(out, 'credentials.txt'),
  people.map((u) => `${u.n}: логін ${u.l}, пароль ${u.p}`).concat(agents.map((a) => `${a.n}: токен ${a.t}`)).join('\n') + '\n', { mode: 0o600 });
console.log('written', path.join(out, '.env'), path.join(out, 'credentials.txt'));
