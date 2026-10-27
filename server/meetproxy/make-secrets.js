// node make-secrets.js <out-dir> — writes <out-dir>/.env for the server and <out-dir>/credentials.txt
// for the people and the two agents. Run once; running again replaces every password and token.
const crypto = require('node:crypto'), fs = require('node:fs'), path = require('node:path');
const out = process.argv[2] || '.';
const pw = () => crypto.randomBytes(12).toString('base64url');
const hash = (p) => { const s = crypto.randomBytes(16); return `scrypt.${s.toString('hex')}.${crypto.scryptSync(p, s, 32).toString('hex')}`; };
const people = [['ivan', 'Іван'], ['volodymyr', 'Володимир']].map(([l, n]) => ({ l, n, p: pw() }));
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
