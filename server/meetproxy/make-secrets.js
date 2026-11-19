// node make-secrets.js <out-dir> — writes <out-dir>/.env for the server and <out-dir>/credentials.txt
// for the people and the two agents. Running again replaces every password and token.
const crypto = require('node:crypto'), fs = require('node:fs'), path = require('node:path');
const out = process.argv[2] || '.';
const pw = () => crypto.randomBytes(12).toString('base64url');
const hash = (p) => { const s = crypto.randomBytes(16); return `scrypt.${s.toString('hex')}.${crypto.scryptSync(p, s, 32).toString('hex')}`; };
// PEOPLE="login:Name,login:Name" names who signs in. The server lowercases the login typed at the
// door and splits its cookie on dots, and USERS is split on commas and colons. So a login is
// lowercase letters, digits, "_" and "-", and appears once. A name is letters, digits, spaces and
// . - ( ) ʼ ’ · only (write an apostrophe as ʼ): no "," or ":" (the list's separators), no "#" (Compose's env_file reads " #"
// as a comment and drops the password hash after it), no quote, "$" or line break. Anything else is
// refused before a file is written.
//
// Running again replaces every password, so over an existing .env it needs PEOPLE spelled out: the
// default (the author and one guest) would silently replace whoever signs in now.
const NAME = /^[\p{L}\p{N} .()ʼ’·-]{1,40}$/u;
function readPeople(spec) {
  const seen = new Set();
  return spec.split(',').map((s) => s.trim()).filter(Boolean).map((entry) => {
    const i = entry.indexOf(':');
    const l = (i < 0 ? entry : entry.slice(0, i)).trim().toLowerCase();
    const n = (i < 0 ? '' : entry.slice(i + 1)).trim();
    if (!/^[a-z0-9_-]{1,32}$/.test(l)) throw new Error(`login «${l}»: only a-z, 0-9, "_" and "-", up to 32`);
    if (!NAME.test(n)) throw new Error(`login «${l}»: the name must be 1–40 letters, digits, spaces or . - ( ) ʼ ’ ·`);
    if (seen.has(l)) throw new Error(`login «${l}» appears twice`);
    seen.add(l);
    return { l, n, p: pw() };
  });
}
let people;
try {
  if (!process.env.PEOPLE && fs.existsSync(path.join(out, '.env')))
    throw new Error(`${path.join(out, '.env')} exists; set PEOPLE to everyone who should sign in, or every account there is replaced`);
  people = readPeople(process.env.PEOPLE || 'ivan:Іван,guest:Гість');
  if (!people.length) throw new Error('PEOPLE names nobody');
  if (process.env.ENDS_AT && !/^[0-9T:.+Z-]{4,40}$/.test(process.env.ENDS_AT)) throw new Error('ENDS_AT is not a date');
} catch (e) {
  console.error(`refused: ${e.message}. Nothing was written.`);
  process.exit(2);
}
const agents = [['claude-bulava', 'Claude · Bulava'], ['claude-factory', 'Claude · фабрика']].map(([id, n]) => ({ id, n, t: 'mp_' + crypto.randomBytes(24).toString('base64url') }));
// Single quotes: Compose's env_file takes the value literally, with no comment, escape or "$".
// Nothing allowed above holds a single quote that could end it early.
const lit = (v) => `'${v}'`;
const env = [
  `SESSION_SECRET=${lit(crypto.randomBytes(32).toString('hex'))}`,
  `USERS=${lit(people.map((u) => `${u.l}:${u.n}:${hash(u.p)}`).join(','))}`,
  `AGENTS=${lit(agents.map((a) => `${crypto.createHash('sha256').update(a.t).digest('hex')}:${a.id}:${a.n}`).join(','))}`,
  `ENDS_AT=${lit(process.env.ENDS_AT || '')}`,
].join('\n') + '\n';
fs.writeFileSync(path.join(out, '.env'), env, { mode: 0o600 });
fs.writeFileSync(path.join(out, 'credentials.txt'),
  people.map((u) => `${u.n}: логін ${u.l}, пароль ${u.p}`).concat(agents.map((a) => `${a.n}: токен ${a.t}`)).join('\n') + '\n', { mode: 0o600 });
console.log('written', path.join(out, '.env'), path.join(out, 'credentials.txt'));
