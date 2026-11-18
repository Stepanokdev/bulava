#!/bin/bash
# The accounts make-secrets.js writes are accounts the server lets in.
#
# PEOPLE became configurable (18 Nov 2026), and with it came logins the server cannot use: "Alice"
# written as is while the door lowercases what is typed, "bob.smith" whose cookie the server splits
# on its dots and then refuses, and one login twice with two passwords of which only the last works.
# Here a config is generated, the server started on it, both people sign in, and each then makes an
# authorised request with the cookie it got. The bad configs are refused before a file is written.
# An empty or unset PEOPLE is the default (the author and one guest), not a refusal.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"; PID=""
trap '[ -n "$PID" ] && kill "$PID" 2>/dev/null; rm -rf "$TMP"' EXIT
fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

echo "===== refused before anything is written ====="
for spec in "bob.smith:Боб" "ivan:Іван,IVAN:Ще Іван" "ivan:" "ivan:Іван: друге" "  , "; do
  d="$TMP/refuse-$RANDOM"; mkdir -p "$d"
  PEOPLE="$spec" node "$HERE/make-secrets.js" "$d" > "$d/out" 2>&1; rc=$?
  if [ "$rc" = 2 ] && [ ! -e "$d/.env" ] && [ ! -e "$d/credentials.txt" ]; then ok "«${spec}» refused, no file written"
  else bad "«${spec}»: rc=$rc, files: $(ls -A "$d" | tr '\n' ' ')"; fi
done

echo "===== two people sign in and use their cookie ====="
d="$TMP/good"; mkdir -p "$d/data"
PEOPLE="Alice:Аліса, bob_smith:Боб" node "$HERE/make-secrets.js" "$d" >/dev/null 2>&1 || bad "a good PEOPLE was refused"
grep -q '^USERS=alice:Аліса:scrypt\.' "$d/.env" && grep -q ',bob_smith:Боб:scrypt\.' "$d/.env" \
  && ok "logins are written lowercase, names as given" || bad "USERS: $(grep ^USERS "$d/.env")"
PORT=$((20000 + RANDOM % 20000))
( set -a; . "$d/.env"; set +a; PORT=$PORT DATA_DIR="$d/data" exec node "$HERE/server.js" ) > "$d/server.log" 2>&1 &
PID=$!
for _ in $(seq 1 50); do curl -s "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break; sleep 0.1; done
for who in alice bob_smith; do
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
  [ "$msgs" = 200 ] && ok "and $who reads the messages" || bad "$who /api/messages: HTTP $msgs"
done

echo
[ "$fails" -eq 0 ] && echo "✅ meetproxy accounts: all checks pass" || echo "❌ meetproxy accounts: $fails failed"
[ "$fails" -eq 0 ]
