#!/bin/bash
# `$IDIR/automation`: a run in one of his chats sees the product's automations and makes one when he
# asks for it — through Bulava, which alone writes them.
#
# Bulava is played here by a loop that answers the request folder the way AutomationDoor does.
# Pinned: a create without its name, when or brief is refused before Bulava is asked, and a flag with
# no value ends at once with exit 2 (it used to loop forever); with no Bulava, or a dead one, the run is
# told at once — and from Codex's sandbox, where Bulava cannot be signalled, its fresh word counts; the
# request carries the run's own project, the brief whole from its file, the mode and confirm-first, and
# the run's id or a Codex chat's turn word; the answers read as lines a run can use; a refusal comes back with
# Bulava's reason; night-shift links the command into every run.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$ROOT/bin"
TMP="$(mktemp -d)"
export SUPERVISOR_STATE_DIR="$TMP/state"
REQ="$SUPERVISOR_STATE_DIR/automation-requests"
mkdir -p "$REQ"
FAKE=""
trap '[ -n "$FAKE" ] && kill "$FAKE" 2>/dev/null; rm -rf "$TMP"' EXIT INT TERM

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

IDIR="$TMP/instance"; PROJ="$TMP/project"
mkdir -p "$IDIR" "$PROJ"
printf '%s\n' "$PROJ" > "$IDIR/project"
printf 'RUN-7\n' > "$IDIR/run-id"
ln -s "$BIN_DIR/worker-automation.sh" "$IDIR/automation"
printf 'Щопонеділка перевір пошукові запити.\nНапиши одну статтю.\n' > "$TMP/brief.md"

fake_bulava() {   # $1 = what every answer says
  ( while :; do
      for f in "$REQ"/*.json; do
        [ -e "$f" ] || continue
        case "$f" in */service.json) continue ;; esac
        id="$(basename "$f" .json)"; [ -e "$REQ/$id.done" ] && continue
        # Gone between the listing and now: the command took its answer and cleaned up.
        cp "$f" "$TMP/last-request.json" 2>/dev/null || continue
        printf '%s' "$1" > "$REQ/$id.done"
      done
      sleep 0.05
    done ) &
  FAKE=$!
}
stop_fake() { kill "$FAKE" 2>/dev/null; wait "$FAKE" 2>/dev/null; FAKE=""; }
# Its exit code, or 124 when it was still going after 3 seconds and had to be stopped.
bounded() {
  "$@" >/dev/null 2>&1 & local p=$! i=0
  while kill -0 "$p" 2>/dev/null; do
    [ "$i" -ge 30 ] && { kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; return 124; }
    sleep 0.1; i=$((i + 1))
  done
  wait "$p"
}

echo "===== incomplete: refused before Bulava is asked ====="
"$IDIR/automation" create --name "SEO" --brief-file "$TMP/brief.md" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "no --when, exit 2" || bad "no when: rc=$rc"
"$IDIR/automation" create --name "SEO" --when "daily 09:00" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "no brief, exit 2" || bad "no brief: rc=$rc"
"$IDIR/automation" dance >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "an unknown action, exit 2" || bad "unknown: rc=$rc"
for flag in --name --when --brief-file; do
  bounded "$IDIR/automation" create "$flag"; rc=$?
  [ "$rc" = 2 ] && ok "$flag with no value: exit 2 at once" || bad "$flag with no value: rc=$rc (124 = never ended)"
done
bounded "$IDIR/automation" create --name --when "daily 09:00" --brief-file "$TMP/brief.md"; rc=$?
[ "$rc" = 2 ] && ok "a flag where the value should be: exit 2" || bad "--name --when: rc=$rc"
"$IDIR/automation" create --when 2>&1 | grep -q -- "--when потребує значення" && ok "and says which flag" || bad "no word on which flag"

echo "===== no Bulava: said at once ====="
out="$("$IDIR/automation" list 2>&1)"; rc=$?
[ "$rc" = 3 ] && ok "no service, exit 3" || bad "no service: rc=$rc out=$out"
printf '{"pid":999999}' > "$REQ/service.json"
out="$("$IDIR/automation" list 2>&1)"; rc=$?
[ "$rc" = 3 ] && ok "a dead pid, exit 3" || bad "dead: rc=$rc out=$out"
# pid 1 is not ours to signal, as Bulava is not from inside Codex's sandbox: a stale word means gone.
printf '{"pid":1}' > "$REQ/service.json"; touch -t 200001010000 "$REQ/service.json"
out="$("$IDIR/automation" list 2>&1)"; rc=$?
[ "$rc" = 3 ] && ok "not signallable and silent for long: exit 3" || bad "stale: rc=$rc out=$out"
printf '{"pid":%s}' "$$" > "$REQ/service.json"

echo "===== list ====="
fake_bulava '{"ok":true,"product":"Pocket Ledger","automations":[{"name":"Weekly SEO","when":"Every Monday at 09:00","on":true,"mode":"branch","lastRun":1791300000},{"name":"Nightly check","when":"Weekdays at 23:30","on":false,"paused":"Two runs in a row failed","mode":"check"}]}'
out="$("$IDIR/automation" list 2>&1)"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | head -1 | grep -q "^Pocket Ledger: 2 automation" && ok "the product and how many" || bad "list head: rc=$rc out=$out"
printf '%s' "$out" | grep -q "^- Weekly SEO · Every Monday at 09:00 · on · changes code on a branch · last run " && ok "each with when, on, mode and the last run" || bad "line: $out"
printf '%s' "$out" | grep -q "^- Nightly check · Weekdays at 23:30 · off (Two runs in a row failed) · only checks and reports" && ok "off, and why" || bad "paused line: $out"
[ "$(jq -r .op "$TMP/last-request.json")" = list ] && [ "$(jq -r .project "$TMP/last-request.json")" = "$PROJ" ] && ok "asked for the run's own project" || bad "request: $(cat "$TMP/last-request.json")"
stop_fake

echo "===== from a Codex chat: no run folder, the turn's word ====="
fake_bulava '{"ok":true,"product":"Pocket Ledger","automations":[]}'
printf '{"pid":1}' > "$REQ/service.json"   # fresh, and not signallable: Bulava as the sandbox sees it
out="$(cd "$PROJ" && BULAVA_CHAT_TURN=w-123 "$BIN_DIR/worker-automation.sh" list 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "Bulava's fresh word is enough where it cannot be signalled" || bad "sandboxed list: rc=$rc out=$out"
cp "$TMP/last-request.json" "$TMP/codex-request.json"
[ "$(jq -r .turn "$TMP/last-request.json")" = w-123 ] && [ "$(jq -r .project "$TMP/last-request.json")" = "$(cd "$PROJ" && pwd -P)" ] \
  && ok "the turn's word and the folder it works in" || bad "codex request: $(cat "$TMP/last-request.json")"
printf '{"pid":%s}' "$$" > "$REQ/service.json"
"$IDIR/automation" list >/dev/null 2>&1
[ "$(jq -r 'has("turn")' "$TMP/last-request.json")" = false ] && [ "$(jq -r .run "$TMP/last-request.json")" = RUN-7 ] \
  && ok "a run's request names its run, and carries no word" || bad "run request: $(cat "$TMP/last-request.json")"
[ "$(jq -r 'has("run")' "$TMP/codex-request.json")" = false ] && ok "a Codex turn's names no run" || bad "codex run: $(cat "$TMP/codex-request.json")"
stop_fake

echo "===== create ====="
fake_bulava '{"ok":true,"id":"A1","name":"Weekly SEO","when":"Every Monday at 09:00","folder":"App"}'
out="$("$IDIR/automation" create --name "Weekly SEO" --when "weekly mon 09:00" --brief-file "$TMP/brief.md" --check-only --confirm-first 2>&1)"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q "^made: «Weekly SEO» — Every Monday at 09:00, in App" && ok "made, said in a line" || bad "create: rc=$rc out=$out"
r="$TMP/last-request.json"
[ "$(jq -r .op "$r")" = create ] && [ "$(jq -r .name "$r")" = "Weekly SEO" ] && [ "$(jq -r .when "$r")" = "weekly mon 09:00" ] \
  && ok "the name and when as given" || bad "fields: $(cat "$r")"
[ "$(jq -r .brief "$r")" = "$(cat "$TMP/brief.md")" ] && ok "the brief whole, from its file" || bad "brief: $(jq -r .brief "$r")"
[ "$(jq -r .mode "$r")" = check ] && [ "$(jq -r .confirmFirst "$r")" = true ] && ok "check-only and confirm-first carried" || bad "mode: $(cat "$r")"
[ -z "$(find "$REQ" -name '*.json' ! -name service.json)" ] && ok "and leaves no request behind" || bad "a request was left behind"
stop_fake

echo "===== refused: Bulava's reason ====="
fake_bulava '{"ok":false,"error":"An automation'"'"'s own run does not make automations. Ask him in one of his chats."}'
out="$("$IDIR/automation" create --name "Loop" --when "hourly 1" --brief-file "$TMP/brief.md" 2>&1)"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q "own run does not make automations" && ok "exit 1, with the reason" || bad "refused: rc=$rc out=$out"
stop_fake

echo "===== every run has it ====="
[ "$(grep -c 'ln -sf "$BIN_DIR/worker-automation.sh" "$IDIR/automation"' "$BIN_DIR/night-shift.sh")" = 2 ] \
  && ok "night-shift links it on a fresh start and on a resume" || bad "night-shift.sh does not link \$IDIR/automation in both places"
grep -q '\$IDIR/automation create' "$ROOT/supervisor/STANDARDS.md" && ok "and the rules tell the run about it" || bad "STANDARDS.md says nothing"

echo
[ "$fails" -eq 0 ] && echo "✅ automation: all checks pass" || echo "❌ automation: $fails failed"
[ "$fails" -eq 0 ]
