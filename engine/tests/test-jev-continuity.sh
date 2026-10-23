#!/bin/bash
# A chat's task outlives its run folder, and Jev — only Jev, only when it is on — decides whether
# the first message after a restart continues it.
#
# Three weeks of real chats paid 4.4M Codex tokens for messages like "the ticket was updated, check
# it": each arrived after the run had been stopped or torn down for idling, found no record of the
# task, and was prepared as a new one — two positions, an alignment, research. Pinned here:
#   • whatever takes a run folder away keeps its task first (stop, a fresh start over it, resume,
#     the idle teardown, the stale cleanup), and an older copy never replaces a newer one
#   • a resume brings the task back only with Jev on, never over a live one, with its queue closed
#   • Jev's "continues" keeps the task (same id, next revision, its material); "new", unsure, an
#     error, shadow mode or Jev switched off since — the old answer, a new task without old material
#   • after a pause or a settled result Jev is asked too; unsure leaves it to the old regex
#   • a message to an open, recent task asks nothing; off asks nothing and reads no key
#   • the key is in no log, record, envelope or child environment
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$ROOT/bin"
unset SUPERVISOR_CHAT_CONTEXT_FILE SUPERVISOR_EXTRA_DIRS_FILE SUPERVISOR_CLAUDE_CMD SUPERVISOR_JEV_MODE SUPERVISOR_JEV_POINTS TYPESAFE_API_KEY
unset SUPERVISOR_REQUIRE_HANDSHAKE SUPERVISOR_HANDSHAKE_WAIT SUPERVISOR_RESUME_HANDSHAKE_WAIT
TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
. "$BIN_DIR/supervisor-lib.sh"
fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [$2]"; fi; }
STUB_PIDS=""
cleanup() { [ -n "$STUB_PIDS" ] && kill $STUB_PIDS 2>/dev/null; tmux_cleanup 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

KEY="ts_test_KEY_0123456789abcdef"
mkdir -p "$TMP/stub" "$TMP/rec"; export REC="$TMP/rec"
cat > "$TMP/stub/key" <<STUB
#!/bin/bash
echo x >> "$TMP/rec/key-reads"
printf '%s' "$KEY"
STUB
cat > "$TMP/stub/curl" <<'STUB'
#!/bin/bash
n=$(( $(ls "$REC" | grep -c '^curl-[0-9]*\.argv$') + 1 ))
printf '%s\n' "$*" > "$REC/curl-$n.argv"
cat > "$REC/curl-$n.stdin"
printf '%s' "${TYPESAFE_API_KEY:-}" > "$REC/curl-$n.envkey"
out=""; req=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; [ "$prev" = "--data-binary" ] && req="${a#@}"; prev="$a"; done
cp "$req" "$REC/curl-$n.req" 2>/dev/null
case "${STUB_HTTP:-200}" in
  200) ;;
  *) printf '{"error":"x"}' > "$out"; printf '%s 0.050' "$STUB_HTTP"; exit 0 ;;
esac
printf '{"model":"jev-1.13.0","usage":{"input_tokens":812},"answers":{"new_task":{"type":"noul","noul":%s}}}' "${STUB_P:-0.05}" > "$out"
printf '200 0.210'
STUB
chmod +x "$TMP/stub/"*
export SUPERVISOR_JEV_KEY_CMD="$TMP/stub/key" SUPERVISOR_JEV_CURL="$TMP/stub/curl"
curls() { ls "$REC" 2>/dev/null | grep -c '^curl-[0-9]*\.argv$'; }
mode() { if [ -n "${1:-}" ]; then printf '%s\n' "$1" > "$SUPERVISOR_STATE_DIR/jev-mode"; else rm -f "$SUPERVISOR_STATE_DIR/jev-mode"; fi; }

PROJ="$TMP/reports-api"; mkdir -p "$PROJ"
( cd "$PROJ" && git init -q && git config user.email t@t && git config user.name t && echo x > f.txt && git add -A && git commit -qm init >/dev/null )
PROJ="$(canon_path "$PROJ")"
SLUG="$(slug_for "$PROJ")"; IDIR="$(instance_dir "$SLUG")"; SES="$(session_name "$SLUG")"
SID="9b1c2d3e-jev-4f5a-8b7c-continuity01"
GOAL="Мы начинаем работать над задачей TKT-101: фильтр отчётов по статусу"
REPLY="Фильтр готов: пять статусов, даты только для Completed. Тесты проходят."

# A run as it is when its folder is about to go: a task with two revisions, the material its
# preparation produced, one message still queued, the session it ran in.
the_run() {   # [$1 = last message epoch]
  rm -rf "$IDIR"; mkdir -p "$IDIR"
  printf '%s\n' "$PROJ" > "$IDIR/project"
  printf 'OLD-RUN\n' > "$IDIR/run-id"
  printf '%s' "$SID" > "$IDIR/claude-session-id"
  thread_bind "$IDIR" "$GOAL" m1 1 new >/dev/null
  thread_bind "$IDIR" "Добавь цвета статусов" m2 2 continue >/dev/null
  thread_delivered "$IDIR" m1; thread_delivered "$IDIR" m2
  thread_bind "$IDIR" "И поправь отступ" m3 3 continue >/dev/null
  printf 'ALIGN-SENTINEL\n' > "$IDIR/peer-alignment.md"
  printf 'RESEARCH-SENTINEL\n' > "$IDIR/research.md"
  printf '{"runspec":1}\n' > "$IDIR/runspec.json"
  printf '%s\n' "$REPLY" > "$IDIR/carried-last-reply.txt"
  if [ -n "${1:-}" ]; then
    jq --argjson t "$1" '.last_message_at = $t' "$(thread_file "$IDIR")" > "$TMP/t.json" && mv "$TMP/t.json" "$(thread_file "$IDIR")"
  fi
}
CARRY="$(thread_carry_dir "$SID")"

echo "===== whatever takes the folder away keeps the task first ====="
the_run
thread_carry_save "$IDIR"
check "the record is kept outside the run folder"        '[ -s "$CARRY/thread/current.json" ] && [ "$(jq -r .revision "$CARRY/thread/current.json")" = 3 ]'
check "with its journal"                                 '[ "$(grep -c . "$CARRY/thread/messages.jsonl")" = 3 ]'
check "the alignment and research come with it"          'grep -q ALIGN-SENTINEL "$CARRY/material/peer-alignment.md" && grep -q RESEARCH-SENTINEL "$CARRY/material/research.md"'
check "a dispatch runspec does not"                      '[ ! -e "$CARRY/material/runspec.json" ]'
check "and Claude's last words, for the question"        'grep -q "Фильтр готов" "$CARRY/last-reply.txt"'
check "the folder is named from the session, not by it"  '! ls "$(thread_carry_root)" | grep -q "$SID"'
the_run 1000
thread_carry_save "$IDIR"
check "an older copy never replaces a newer one"         '[ "$(jq -r .last_message_at "$CARRY/thread/current.json")" != 1000 ]'
for site in 'night-shift.sh:.*thread_carry_save "\$idir"' 'night-shift.sh:.*thread_carry_save "\$IDIR"' 'watchdog.sh:.*thread_carry_save' 'safety-check.sh:.*thread_carry_save'; do
  grep -rnE "thread_carry_save" "$BIN_DIR/night-shift.sh" "$BIN_DIR/watchdog.sh" "$ROOT/hooks/safety-check.sh" | sed "s|$ROOT/||" | grep -qE "$site" \
    && ok "saved before removal: ${site%%:*}" || bad "no save before removal: $site"
done
check "stop, fresh start and resume all save"            '[ "$(grep -c "thread_carry_save" "$BIN_DIR/night-shift.sh")" = 3 ]'
check "a rolled-back start or resume does not"           '! sed -n "/rollback_start() {/,/^    }/p;/resume_rollback() {/,/^    }/p" "$BIN_DIR/night-shift.sh" | grep -q thread_carry_save'

echo "===== a resume brings it back only with Jev on ====="
fresh() { rm -rf "$IDIR"; mkdir -p "$IDIR"; printf '%s\n' "$PROJ" > "$IDIR/project"; printf 'NEW-RUN\n' > "$IDIR/run-id"; }
the_run; thread_carry_save "$IDIR"; rm -rf "$REC"; mkdir -p "$REC"
mode ""; fresh; thread_carry_restore "$IDIR" "$SID"
check "off: nothing comes back"                          '[ ! -e "$(thread_file "$IDIR")" ] && [ ! -e "$IDIR/peer-alignment.md" ]'
check "off: the Keychain is not even read"               '[ ! -e "$REC/key-reads" ]'
mode on; fresh; thread_carry_restore "$IDIR" "$SID"
check "on: the record is back, marked as carried"        '[ "$(thread_get "$IDIR" .revision)" = 3 ] && [ -n "$(thread_get "$IDIR" .carried_at)" ] && [ "$(thread_get "$IDIR" .carried_from_run)" = OLD-RUN ]'
check "with its material"                                'grep -q ALIGN-SENTINEL "$IDIR/peer-alignment.md" && grep -q RESEARCH-SENTINEL "$IDIR/research.md"'
check "the message still queued is not owed any more"    '[ "$(jq -c "select(.delivered != true)" "$(thread_log "$IDIR")" | grep -c .)" = 0 ] && jq -e "select(.message_id == \"m3\") | .lost_at_restart == true" "$(thread_log "$IDIR")" >/dev/null'
fresh; thread_bind "$IDIR" "A live task" x1 1 new >/dev/null; thread_carry_restore "$IDIR" "$SID"
check "never over a live task"                           '[ "$(thread_get "$IDIR" .objective)" = "A live task" ] && [ ! -e "$IDIR/peer-alignment.md" ]'

carried() { mode "${1:-on}"; fresh; thread_carry_restore "$IDIR" "$SID"; rm -rf "$REC"; mkdir -p "$REC"; }
enqueue() { ENV="$(pending_enqueue "$IDIR" "$1" "${2:-msg-x}" adaptive-peer)"; }
TID_OLD="$(jq -r .thread_id "$CARRY/thread/current.json")"

echo "===== Jev says it continues: the task goes on ====="
carried on; STUB_P=0.05 enqueue "тикет был снова обновлен, проверяй"
check "the envelope says continue"                       '[ "$(jq -r .relation "$ENV")" = continue ]'
check "the same task, its next revision"                 '[ "$(jq -r .thread_id "$ENV")" = "$TID_OLD" ] && [ "$(jq -r .revision "$ENV")" = 4 ]'
check "the carried mark is gone after the first message" '[ -z "$(thread_get "$IDIR" .carried_at)" ]'
check "its material stays for the follow-up"             'grep -q ALIGN-SENTINEL "$IDIR/peer-alignment.md"'
check "the reply snapshot and the marker have served"    '[ ! -e "$IDIR/carried-last-reply.txt" ] && [ ! -e "$IDIR/carried-material" ]'
check "one call to Jev"                                  '[ "$(curls)" = 1 ]'
check "the key reaches curl on stdin, not in its argv"   'grep -q "Authorization: Bearer $KEY" "$REC/curl-1.stdin" && ! grep -q -- "$KEY" "$REC/curl-1.argv"'
check "and not through its environment"                  '[ ! -s "$REC/curl-1.envkey" ]'
check "what was sent: the goal, Claude's reply, the message" 'jq -e --arg g "$GOAL" ".state.task == \$g and (.state.last_reply_from_the_agent | test(\"Фильтр готов\")) and (.state.new_message | test(\"обновлен\")) and .model == \"jev-1.13.0\"" "$REC/curl-1.req" >/dev/null'
check "the decision is logged with its case and cost"    'tail -1 "$SUPERVISOR_STATE_DIR/jev/relation.jsonl" | jq -e ".case == \"carried\" and .verdict == \"continue\" and .applied == \"continue\" and .input_tokens == 812 and .p == 0.05" >/dev/null'

echo "===== a follow-up prepared on it asks no model and reads the old agreement ====="
cat > "$TMP/stub/codex" <<'STUB'
#!/bin/bash
echo x >> "$REC/codex-calls"; exit 0
STUB
chmod +x "$TMP/stub/codex"
ART="$TMP/art"; mkdir -p "$ART"
( cd "$PROJ" && PATH="$TMP/stub:$PATH" PIPE_RELATION=continue bash "$BIN_DIR/preflight.sh" --art "$ART" --stage context "$PROJ" "тикет был снова обновлен, проверяй" ) >/dev/null 2>&1
check "the follow-up path: no classification, no research" '[ "$(jq -r .scale "$ART/preflight.json")" = followup ] && [ ! -e "$REC/codex-calls" ]'
check "the brief carries the task and its agreement"     'grep -q "TKT-101" "$ART/context.md" && grep -q ALIGN-SENTINEL "$ART/context.md"'
check "and the research it already paid for"             'grep -q RESEARCH-SENTINEL "$ART/research.md"'

echo "===== new, unsure, an error, shadow, switched off: the old answer ====="
for c in "new:0.97" "unsure:0.5" "malformed:e"; do
  carried on; STUB_P="${c#*:}" enqueue "у нас новая задача - TKT-202 обновить логотип"
  check "${c%%:*}: a new task"                           '[ "$(jq -r .relation "$ENV")" = new ] && [ "$(jq -r .thread_id "$ENV")" != "$TID_OLD" ]'
  check "${c%%:*}: and the old task's material is gone"  '[ ! -e "$IDIR/peer-alignment.md" ] && [ ! -e "$IDIR/research.md" ]'
done
carried on; STUB_HTTP=429 enqueue "тикет был снова обновлен, проверяй"
check "429: a new task, after one retry"                 '[ "$(jq -r .relation "$ENV")" = new ] && [ "$(curls)" = 2 ]'
tail -1 "$SUPERVISOR_STATE_DIR/jev/relation.jsonl" | jq -e '.verdict == "unsure" and .applied == "new" and .error == "http-429"' >/dev/null \
  && ok "and the log names the error" || bad "log: $(tail -1 "$SUPERVISOR_STATE_DIR/jev/relation.jsonl")"
carried shadow; STUB_P=0.05 enqueue "тикет был снова обновлен, проверяй"
check "shadow: Jev is asked, the old rule decides"       '[ "$(jq -r .relation "$ENV")" = new ] && [ "$(curls)" = 1 ]'
tail -1 "$SUPERVISOR_STATE_DIR/jev/relation.jsonl" | jq -e '.mode == "shadow" and .verdict == "continue" and .applied == "new"' >/dev/null \
  && ok "and the log keeps what Jev would have done" || bad "log: $(tail -1 "$SUPERVISOR_STATE_DIR/jev/relation.jsonl")"
carried on; mode off; STUB_P=0.05 enqueue "тикет был снова обновлен, проверяй"
check "switched off after the restore: a new task, no call" '[ "$(jq -r .relation "$ENV")" = new ] && [ "$(curls)" = 0 ] && [ ! -e "$IDIR/peer-alignment.md" ]'

echo "===== a verdict about a task that has moved on is not applied to the next one ====="
carried on
HINT="$(STUB_P=0.97 jev_relation_for "$IDIR" "у нас новая задача - TKT-202 обновить логотип" mx)"
check "Jev's verdict names the task it was about"        '[ "$HINT" = "new $TID_OLD" ]'
# …and before it is bound, another message opens task B, with B's own preparation material
thread_bind "$IDIR" "Задача B" b1 9 new >/dev/null
printf 'B-ALIGN\n' > "$IDIR/peer-alignment.md"
TID_B="$(thread_get "$IDIR" .thread_id)"
OUT="$(thread_bind "$IDIR" "у нас новая задача - TKT-202 обновить логотип" mx 10 new "$TID_OLD")"
check "the stale verdict is dropped: the rule decides on B" '[ "${OUT%% *}" = continue ] && [ "$(thread_get "$IDIR" .thread_id)" = "$TID_B" ]'
check "and B's material is untouched"                    'grep -q B-ALIGN "$IDIR/peer-alignment.md"'

echo "===== two saves in the same second keep the later revision ====="
the_run; thread_carry_save "$IDIR"
NOW="$(date +%s)"
thread_bind "$IDIR" "ещё одно" m4 4 continue >/dev/null
jq --argjson t "$NOW" '.last_message_at = $t' "$(thread_file "$IDIR")" > "$TMP/t.json" && mv "$TMP/t.json" "$(thread_file "$IDIR")"
thread_carry_save "$IDIR"
cp -R "$IDIR" "$TMP/older"; jq --argjson t "$NOW" '.revision = 3 | .last_message_at = $t' "$(thread_file "$TMP/older")" > "$TMP/t.json" && mv "$TMP/t.json" "$(thread_file "$TMP/older")"
thread_carry_save "$TMP/older"; rm -rf "$TMP/older"
check "an older revision saved later does not win"       '[ "$(jq -r .revision "$CARRY/thread/current.json")" = 4 ]'

echo "===== after a pause or a result, Jev is asked too ====="
mode on
paused() { fresh; thread_bind "$IDIR" "$GOAL" p1 1 new >/dev/null; jq --argjson t "$(( $(date +%s) - 8 * 3600 ))" '.last_message_at = $t' "$(thread_file "$IDIR")" > "$TMP/t.json" && mv "$TMP/t.json" "$(thread_file "$IDIR")"; rm -rf "$REC"; mkdir -p "$REC"; }
paused; STUB_P=0.05 enqueue "Давай вернемся к реализации, затем прогони енд ту енд тестирование"
check "8h quiet, Jev: continues"                         '[ "$(jq -r .relation "$ENV")" = continue ] && [ "$(curls)" = 1 ]'
paused; STUB_P=0.97 enqueue "Теперь другая задача: экспорт отчёта в CSV"
check "8h quiet, Jev: a new task"                        '[ "$(jq -r .relation "$ENV")" = new ]'
paused; STUB_P=0.5 enqueue "Давай вернемся к реализации"
check "8h quiet, unsure: the old regex decides"          '[ "$(jq -r .relation "$ENV")" = continue ] && tail -1 "$SUPERVISOR_STATE_DIR/jev/relation.jsonl" | jq -e ".applied == \"old-rule\"" >/dev/null'
fresh; thread_bind "$IDIR" "$GOAL" s1 1 new >/dev/null; thread_settle "$IDIR" succeeded_changes d1; rm -rf "$REC"; mkdir -p "$REC"
STUB_P=0.05 enqueue "закоммить и запушь"
check "a settled task asks Jev"                          '[ "$(jq -r .relation "$ENV")" = continue ] && [ "$(curls)" = 1 ] && tail -1 "$SUPERVISOR_STATE_DIR/jev/relation.jsonl" | jq -e ".case == \"settled\"" >/dev/null'
fresh; thread_bind "$IDIR" "$GOAL" r1 1 new >/dev/null; rm -rf "$REC"; mkdir -p "$REC"
STUB_P=0.97 enqueue "Конпка закрытия закрашивается, поправь"
check "an open, recent task asks nothing"                '[ "$(jq -r .relation "$ENV")" = continue ] && [ "$(curls)" = 0 ]'
mode off; paused; STUB_P=0.05 enqueue "Давай вернемся к реализации"
check "off: no call and no Keychain read"                '[ "$(curls)" = 0 ] && [ ! -e "$REC/key-reads" ]'

echo "===== through a real resume ====="
if command -v tmux >/dev/null 2>&1; then
  tmux_isolate "$TMP/tmux"
  printf '#!/bin/bash\nsleep 120\n' > "$TMP/watchdog-stub"; chmod +x "$TMP/watchdog-stub"
  export SUPERVISOR_WATCHDOG_CMD="$TMP/watchdog-stub" SUPERVISOR_ENABLE_RESUME=1 SUPERVISOR_NO_ATTACH=1
  confirm="$(printf ': > %s; sleep 120' "$(shq "$IDIR/handshake-ok")")"
  resume_now() { ( cd "$PROJ" && SUPERVISOR_CLAUDE_CMD="$confirm" bash "$BIN_DIR/night-shift.sh" resume "$PROJ" "$SID" - --no-attach >/dev/null 2>&1 ); rc=$?
                 STUB_PIDS="$(cat "$IDIR/watchdog.pid" 2>/dev/null)"; }
  stop_now() { tmux kill-session -t "$SES" 2>/dev/null; [ -n "$STUB_PIDS" ] && kill $STUB_PIDS 2>/dev/null; STUB_PIDS=""; }
  rm -rf "$CARRY"; mode on
  the_run; resume_now
  check "the resume came up"                             '[ "$rc" = 0 ] && [ "$(cat "$IDIR/run-id")" != OLD-RUN ]'
  check "and its folder has the task the old one had"     '[ "$(thread_get "$IDIR" .revision)" = 3 ] && [ -n "$(thread_get "$IDIR" .carried_at)" ] && grep -q ALIGN-SENTINEL "$IDIR/peer-alignment.md"'
  stop_now
  rm -rf "$CARRY"; mode off
  the_run; resume_now
  check "with Jev off the resumed folder starts empty, as before" '[ "$rc" = 0 ] && [ ! -e "$(thread_file "$IDIR")" ]'
  check "but the task was still kept, for when Jev is on" '[ -s "$CARRY/thread/current.json" ]'
  stop_now
else
  echo "  (tmux not installed — skipped)"
fi

echo "===== the key stays out of everything ====="
grep -rl -- "$KEY" "$SUPERVISOR_STATE_DIR" "$REC"/curl-*.argv "$REC"/curl-*.req 2>/dev/null | grep -q . \
  && bad "the key was written: $(grep -rl -- "$KEY" "$SUPERVISOR_STATE_DIR" "$REC"/curl-*.argv 2>/dev/null | head -3)" \
  || ok "no state file, log, envelope, argv or request holds the key"
check "TYPESAFE_API_KEY is stripped like the other paid keys" '[ "$(TYPESAFE_API_KEY=leak bash -c ". \"$BIN_DIR/supervisor-lib.sh\"; strip_paid_api_env >/dev/null 2>&1; printf %s \"\${TYPESAFE_API_KEY:-gone}\"")" = gone ]'
out="$(bash "$BIN_DIR/jev.sh" status --json 2>/dev/null)"
check "jev.sh status --json: mode and key, never the key" 'printf "%s" "$out" | jq -e ".key == true and (.mode | type) == \"string\"" >/dev/null && ! printf "%s" "$out" | grep -q -- "$KEY"'
check "jev.sh refuses a mode it does not know"           '! bash "$BIN_DIR/jev.sh" mode sideways >/dev/null 2>&1'
check "and a key handed over that is not one"            '! JEV_HANDED_KEY="not a key" bash "$BIN_DIR/jev.sh" key set --env >/dev/null 2>&1'

[ "$fails" -eq 0 ] && { echo "✅ jev continuity: all passed"; exit 0; } || { echo "❌ jev continuity: $fails failed"; exit 1; }
