#!/bin/bash
# The accounts make-secrets.js writes are accounts the server lets in, as Docker Compose loads them.
#
# PEOPLE became configurable (18 Nov 2026), and with it came accounts nobody could use: "Alice"
# written as is while the door lowercases what is typed; "bob.smith", whose cookie the server
# splits on its dots and refuses; one login twice; a name with " #", which Compose's env_file reads
# as a comment, cutting off the password hash and every account after it; a name with a line break
# that split USERS in two. And a second run with no PEOPLE replaced whoever signed in with a guest.
#
# The good config goes through `docker compose config` (the same reading of .env the deployment
# gets), the server is started on exactly that environment, both people sign in, and each makes an
# authorised request with its cookie. Without Docker the test says so and fails: that reading is the
# point.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"; PID=""
trap '[ -n "$PID" ] && kill "$PID" 2>/dev/null; rm -rf "$TMP"' EXIT
fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

echo "===== refused before anything is written ====="
NL=$'\n'
for spec in "bob.smith:Боб" "ivan:Іван,IVAN:Ще Іван" "ivan:" "ivan:Іван: друге" "  , " \
            "alice:Alice #1" "rev:Ревʼюер #2" "ivan:Іван${NL}EVIL=1" "q:O'Brien" "d:\$HOME" "e:\"Eve\""; do
  d="$TMP/refuse-$RANDOM$RANDOM"; mkdir -p "$d"
  PEOPLE="$spec" node "$HERE/make-secrets.js" "$d" > "$d/out" 2>&1; rc=$?
  shown="$(printf '%s' "$spec" | tr '\n' '|')"
  if [ "$rc" = 2 ] && [ ! -e "$d/.env" ] && [ ! -e "$d/credentials.txt" ]; then ok "«${shown}» refused, no file written"
  else bad "«${shown}»: rc=$rc, files: $(ls -A "$d" | tr '\n' ' ')"; fi
done

echo "===== a second run keeps nobody out by accident ====="
d="$TMP/rerun"; mkdir -p "$d"
PEOPLE="ivan:Іван,olena:Олена" node "$HERE/make-secrets.js" "$d" >/dev/null 2>&1
before="$(cat "$d/.env")"
env -u PEOPLE node "$HERE/make-secrets.js" "$d" > "$d/out" 2>&1; rc=$?
[ "$rc" = 2 ] && [ "$(cat "$d/.env")" = "$before" ] && grep -q "set PEOPLE" "$d/out" \
  && ok "no PEOPLE over an existing .env: refused, the old .env untouched" || bad "rerun without PEOPLE: rc=$rc $(cat "$d/out")"
PEOPLE="ivan:Іван,olena:Олена" node "$HERE/make-secrets.js" "$d" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$d/.env")" != "$before" ] && ok "with PEOPLE spelled out it rewrites" || bad "rerun with PEOPLE: rc=$rc"

echo "===== two people sign in, with the environment Compose builds ====="
if ! docker compose version >/dev/null 2>&1; then
  bad "docker compose is not available: the .env cannot be read the way the deployment reads it"
else
  d="$TMP/good"; mkdir -p "$d/data"
  cp "$HERE/docker-compose.yml" "$d/"
  PEOPLE="Alice:Аліса (QA),rev:Ревʼюер-2 · Bulava" node "$HERE/make-secrets.js" "$d" >/dev/null 2>&1 || bad "a good PEOPLE was refused"
  docker compose -f "$d/docker-compose.yml" config --format json > "$d/config.json" 2>"$d/config.err" \
    || bad "docker compose config: $(cat "$d/config.err")"
  python3 - "$d/config.json" "$d/env.sh" <<'PY' || bad "Compose's environment could not be read"
import json, shlex, sys
env = json.load(open(sys.argv[1]))["services"]["app"]["environment"]
with open(sys.argv[2], "w") as fh:
    for k in ("SESSION_SECRET", "USERS", "AGENTS", "ENDS_AT"):
        fh.write(f"export {k}={shlex.quote(env.get(k) or '')}\n")
users = env["USERS"].split(",")
assert len(users) == 2 and all(len(u.split(":")) == 3 and u.split(":")[2].startswith("scrypt.") for u in users), users
PY
  grep -q "USERS='alice:Аліса (QA):scrypt\." "$d/env.sh" && grep -q ",rev:Ревʼюер-2 · Bulava:scrypt\." "$d/env.sh" \
    && ok "Compose reads both accounts whole: lowercase login, name as given, a hash each" \
    || bad "Compose's USERS: $(grep USERS "$d/env.sh")"
  PORT=$((20000 + RANDOM % 20000))
  ( . "$d/env.sh"; PORT=$PORT DATA_DIR="$d/data" exec node "$HERE/server.js" ) > "$d/server.log" 2>&1 &
  PID=$!
  for _ in $(seq 1 50); do curl -s "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break; sleep 0.1; done
  for who in alice rev; do
    pass="$(grep -E "логін $who, пароль " "$d/credentials.txt" | sed 's/.*пароль //')"
    typed="$who"; [ "$who" = alice ] && typed="Alice"   # the door lowercases what is typed
    code="$(curl -s -o /dev/null -w '%{http_code}' -c "$TMP/$who.jar" -H 'Content-Type: application/json' \
            -d "{\"login\":\"$typed\",\"password\":\"$pass\"}" "http://127.0.0.1:$PORT/login")"
    [ "$code" = 200 ] && ok "${typed} signs in" || bad "${typed} sign-in: HTTP $code $(tail -3 "$d/server.log")"
    # The cookie is Secure; curl will not send it back over http, so it is passed by hand.
    cookie="$(awk '$6=="mp"{print $7}' "$TMP/$who.jar")"
    me="$(curl -s -H "Cookie: mp=$cookie" "http://127.0.0.1:$PORT/api/me")"
    printf '%s' "$me" | grep -q "\"id\":\"$who\"" && ok "and ${who}'s next request is authorised" || bad "$who /api/me: $me"
    msgs="$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: mp=$cookie" "http://127.0.0.1:$PORT/api/messages?after=0")"
    [ "$msgs" = 200 ] && ok "and ${who} reads the messages" || bad "$who /api/messages: HTTP $msgs"
  done
fi

echo
[ "$fails" -eq 0 ] && echo "✅ meetproxy accounts: all checks pass" || echo "❌ meetproxy accounts: $fails failed"
[ "$fails" -eq 0 ]
