#!/bin/bash
# `$IDIR/decide`: an agent puts a report with questions into its chat, for Bulava to draw the choices.
#
# Bulava is played here by a loop that answers the request folder the way DecisionCenter does.
# Pinned: a report with no decisions.json beside it, or one with nothing to decide, is refused
# before Bulava is asked; with no Bulava, or a dead one, the agent is told at once to ask in the
# chat instead; the request carries the absolute path and the run's own project; the answer names
# the chat; a refusal comes back with Bulava's reason; silence ends in a bounded wait.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$ROOT/bin"
TMP="$(mktemp -d)"
export SUPERVISOR_STATE_DIR="$TMP/state"
REQ="$SUPERVISOR_STATE_DIR/decision-requests"
mkdir -p "$REQ"
FAKE=""
trap '[ -n "$FAKE" ] && kill "$FAKE" 2>/dev/null; rm -rf "$TMP"' EXIT INT TERM

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

# A run folder, the way night-shift.sh makes it: its project, and decide linked into it.
IDIR="$TMP/instance"; PROJ="$TMP/project"
mkdir -p "$IDIR" "$PROJ/artifacts/plan" "$PROJ/artifacts/bare"
printf '%s\n' "$PROJ" > "$IDIR/project"
ln -s "$BIN_DIR/worker-decide.sh" "$IDIR/decide"
printf '<h1>Plan</h1>' > "$PROJ/artifacts/plan/index.html"
printf '<h1>Bare</h1>' > "$PROJ/artifacts/bare/index.html"
printf '{"title":"Що далі","items":[{"id":"leak","title":"Закрити витік"}]}' > "$PROJ/artifacts/plan/decisions.json"

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

echo "===== nothing to decide: refused before Bulava is asked ====="
out="$(cd "$PROJ" && "$IDIR/decide" artifacts/bare/index.html 2>&1)"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q "decisions.json" && ok "no decisions.json beside it, exit 1" || bad "bare: rc=$rc out=$out"
printf '{"items":[]}' > "$PROJ/artifacts/bare/decisions.json"
out="$(cd "$PROJ" && "$IDIR/decide" artifacts/bare/index.html 2>&1)"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q "items" && ok "an empty list of questions, exit 1" || bad "empty: rc=$rc out=$out"

echo "===== no Bulava: said at once ====="
out="$(cd "$PROJ" && "$IDIR/decide" artifacts/plan/index.html 2>&1)"; rc=$?
[ "$rc" = 3 ] && printf '%s' "$out" | grep -q "не запущений" && ok "no service, exit 3 — ask in the chat" || bad "no service: rc=$rc out=$out"
printf '{"pid":999999}' > "$REQ/service.json"
out="$(cd "$PROJ" && "$IDIR/decide" artifacts/plan/index.html 2>&1)"; rc=$?
[ "$rc" = 3 ] && printf '%s' "$out" | grep -q "більше не працює" && ok "a dead pid, exit 3" || bad "dead service: rc=$rc out=$out"

echo "===== published: the chat is named ====="
printf '{"pid":%s}' "$$" > "$REQ/service.json"
fake_bulava '{"ok":true,"chat":"Експорт","report":"/p/artifacts/plan/index.html"}'
out="$(cd "$PROJ" && "$IDIR/decide" artifacts/plan/index.html 2>&1)"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q "«Експорт»" && ok "exit 0, the chat named" || bad "published: rc=$rc out=$out"
[ "$(jq -r .path "$TMP/last-request.json")" = "$(cd "$PROJ" && pwd -P)/artifacts/plan/index.html" ] && ok "the request names the absolute path" \
  || bad "path in the request: $(cat "$TMP/last-request.json")"
[ "$(jq -r .project "$TMP/last-request.json")" = "$PROJ" ] && ok "and the run's own project" || bad "project: $(cat "$TMP/last-request.json")"
ls "$REQ"/*.done >/dev/null 2>&1 && bad "the answer was left behind" || ok "and leaves nothing behind"
kill "$FAKE" 2>/dev/null; wait "$FAKE" 2>/dev/null; FAKE=""

echo "===== refused: the reason comes back ====="
fake_bulava '{"ok":false,"error":"item 1: \"recommended\" must be one of its options"}'
out="$(cd "$PROJ" && "$IDIR/decide" artifacts/plan/index.html 2>&1)"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q "recommended" && ok "refused, exit 1 with Bulava's words" || bad "refused: rc=$rc out=$out"
kill "$FAKE" 2>/dev/null; wait "$FAKE" 2>/dev/null; FAKE=""

echo "===== nobody answers: a bounded wait ====="
start=$(date +%s)
out="$(cd "$PROJ" && NS_DECIDE_TIMEOUT=1 "$IDIR/decide" artifacts/plan/index.html 2>&1)"; rc=$?
[ "$rc" = 4 ] && [ $(( $(date +%s) - start )) -le 4 ] && ok "gives up after its timeout, exit 4" || bad "timeout: rc=$rc out=$out"
ls "$REQ"/*.json 2>/dev/null | grep -v service.json >/dev/null && bad "an abandoned request was left for Bulava to answer later" \
  || ok "and takes its request back"

echo
[ "$fails" -eq 0 ] && echo "✅ decide: all checks pass" || echo "❌ decide: $fails failed"
[ "$fails" -eq 0 ]
