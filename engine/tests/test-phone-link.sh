#!/bin/bash
# `$IDIR/phone-link`: an agent asks Bulava to show something on the director's phone.
#
# Bulava is played here by a loop that answers the request folder the way ShareCenter does. Pinned:
# with no Bulava, a dead one, or the setting off, the agent is told so at once (never a hang); a
# request carries the absolute path and the run's own project; the links come back one per line;
# a refusal comes back with its reason; and silence ends in a bounded wait.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$ROOT/bin"
TMP="$(mktemp -d)"
export SUPERVISOR_STATE_DIR="$TMP/state"
REQ="$SUPERVISOR_STATE_DIR/share-requests"
mkdir -p "$REQ"
FAKE=""
trap '[ -n "$FAKE" ] && kill "$FAKE" 2>/dev/null; rm -rf "$TMP"' EXIT INT TERM

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

# A run folder, the way night-shift.sh makes it: its project, and phone-link linked into it.
IDIR="$TMP/instance"; PROJ="$TMP/project"
mkdir -p "$IDIR" "$PROJ/artifacts/site"
printf '%s\n' "$PROJ" > "$IDIR/project"
ln -s "$BIN_DIR/worker-share.sh" "$IDIR/phone-link"
: > "$PROJ/artifacts/site/index.html"

fake_bulava() {   # $1 = what every answer says
  ( while :; do
      for f in "$REQ"/*.json; do
        [ -e "$f" ] || continue
        case "$f" in */service.json) continue ;; esac
        id="$(basename "$f" .json)"; [ -e "$REQ/$id.done" ] && continue
        cp "$f" "$TMP/last-request.json"
        printf '%s' "$1" > "$REQ/$id.done"
      done
      sleep 0.05
    done ) &
  FAKE=$!
}

echo "===== no Bulava: said at once ====="
out="$(cd "$PROJ" && "$IDIR/phone-link" artifacts/site 2>&1)"; rc=$?
[ "$rc" = 3 ] && printf '%s' "$out" | grep -q "не запущений" && ok "no service, exit 3 with the reason" || bad "no service: rc=$rc out=$out"

echo "===== a Bulava that died: said at once ====="
printf '{"pid":999999,"enabled":true}' > "$REQ/service.json"
out="$(cd "$PROJ" && "$IDIR/phone-link" artifacts/site 2>&1)"; rc=$?
[ "$rc" = 3 ] && printf '%s' "$out" | grep -q "більше не працює" && ok "a dead pid, exit 3" || bad "dead service: rc=$rc out=$out"

echo "===== switched off in Settings ====="
printf '{"pid":%s,"enabled":false}' "$$" > "$REQ/service.json"
out="$(cd "$PROJ" && "$IDIR/phone-link" artifacts/site 2>&1)"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q "вимкнені" && ok "the setting off, exit 1 with the reason" || bad "off: rc=$rc out=$out"

echo "===== shared: the links, one per line ====="
printf '{"pid":%s,"enabled":true}' "$$" > "$REQ/service.json"
fake_bulava '{"ok":true,"token":"T","scope":"site","urls":["http://mac.local:47292/s/T/index.html","http://[fe80::1]:47292/s/T/index.html"]}'
out="$(cd "$PROJ" && "$IDIR/phone-link" artifacts/site --title "Звіт" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | head -1)" = "http://mac.local:47292/s/T/index.html" ] \
  && [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 2 ] && ok "two links, the Bonjour name first" || bad "shared: rc=$rc out=$out"
[ "$(jq -r .path "$TMP/last-request.json")" = "$(cd "$PROJ" && pwd -P)/artifacts/site" ] && ok "the request names the absolute path" \
  || bad "path in the request: $(cat "$TMP/last-request.json")"
[ "$(jq -r .project "$TMP/last-request.json")" = "$PROJ" ] && ok "and the run's own project" || bad "project: $(cat "$TMP/last-request.json")"
[ "$(jq -r .title "$TMP/last-request.json")" = "Звіт" ] && ok "and the title" || bad "title"
ls "$REQ"/*.done >/dev/null 2>&1 && bad "the answer was left behind" || ok "and leaves nothing behind"
kill "$FAKE" 2>/dev/null; wait "$FAKE" 2>/dev/null; FAKE=""

echo "===== refused: the reason comes back ====="
fake_bulava '{"ok":false,"error":"A whole project folder is never shared."}'
out="$(cd "$PROJ" && "$IDIR/phone-link" . 2>&1)"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q "never shared" && ok "refused, exit 1 with Bulava's words" || bad "refused: rc=$rc out=$out"
kill "$FAKE" 2>/dev/null; wait "$FAKE" 2>/dev/null; FAKE=""

echo "===== nobody answers: a bounded wait ====="
start=$(date +%s)
out="$(cd "$PROJ" && NS_SHARE_TIMEOUT=1 "$IDIR/phone-link" artifacts/site 2>&1)"; rc=$?
[ "$rc" = 4 ] && [ $(( $(date +%s) - start )) -le 4 ] && ok "gives up after its timeout, exit 4" || bad "timeout: rc=$rc out=$out"
ls "$REQ"/*.json 2>/dev/null | grep -v service.json >/dev/null && bad "an abandoned request was left for Bulava to answer later" \
  || ok "and takes its request back"

echo
[ "$fails" -eq 0 ] && echo "✅ phone-link: all checks pass" || echo "❌ phone-link: $fails failed"
[ "$fails" -eq 0 ]
