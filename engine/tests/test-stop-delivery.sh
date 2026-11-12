#!/bin/bash
# The director's words reach a busy worker at its next stop (stop_followup_head, the review gate,
# pipeline-deliver.sh with SUPERVISOR_DELIVER_TO_FILE):
#   • a follow-up to the current task is prepared by the usual pipeline and handed over as the stop's
#     reason, before any review against the old instruction — in an ordinary run and in a long
#     project alike; its envelope is gone, it is marked delivered, the old outcome is set aside
#   • the next review is told about it, though Stop-hook feedback is left out of the human turns
#   • a new task is never mixed in: it stays queued, and stops the follow-ups behind it
#   • a message taken back, one for another run or thread, or a pipeline already at work: left to
#     the pump, untouched
#   • a long project yields to a waiting new task at the end of the piece instead of the next one
#   • the pipeline does not prepare a message whose envelope left the queue while it waited
# Tenders automation, 5 Nov: a scope change waited 3 h 26 min, its follow-up 7 h 27 min, because the
# gate kept the long project's turn going from piece to piece.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SUPERVISOR_STATE_DIR="$(mktemp -d)"
. "$ROOT/bin/supervisor-lib.sh"
GATE="$ROOT/hooks/review-gate.sh"
export SUPERVISOR_CODEX_USAGE_CMD="/usr/bin/true" SUPERVISOR_CLAUDE_USAGE_CMD="/usr/bin/true"
export CODEX_SESSIONS_DIR="$(mktemp -d)"
# A real inject would type into tmux; any call to it here is a delivery that should not happen.
export SUPERVISOR_INJECT_CMD="$SUPERVISOR_STATE_DIR/inject-should-not-run"
printf '#!/bin/bash\necho typed >> "%s/typed"\nexit 0\n' "$SUPERVISOR_STATE_DIR" > "$SUPERVISOR_INJECT_CMD"; chmod +x "$SUPERVISOR_INJECT_CMD"

pass=0; fail=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
no(){ echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

FAKE="$(mktemp -d)"; CALLED="$FAKE/called"
cat > "$FAKE/codex" <<'EOF'
#!/bin/bash
if [ "${1:-}" = login ]; then echo "Logged in using ChatGPT"; exit 0; fi
if echo "$*" | grep -q "HANDOFF | BLOCKED"; then
  printf '%s\n' "${@: -1}" > "$CALLED"; echo "STATE: COMPLETE"; echo "VERDICT: PASS"; exit 0
fi
echo "VERDICT: PASS"
EOF
chmod +x "$FAKE/codex"; export CALLED
TR="$(mktemp)"; printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"text","text":"роблю шматок"}]}}' > "$TR"
REPOS=()
cleanup(){ rm -rf "$SUPERVISOR_STATE_DIR" "$FAKE" "$TR" "$CODEX_SESSIONS_DIR" ${REPOS[@]+"${REPOS[@]}"}; }
trap cleanup EXIT

THREAD="thread-tenders"
piece(){ ( cd "$PROJ" && ORCHESTRATOR_RUN_ID="$RID" bash "$ROOT/bin/piece.sh" "$@" ); }
mkcase(){   # [long] — a long project with a piece open
  RID="stop-run-$RANDOM$RANDOM"
  PROJ="$(mktemp -d)"; REPOS+=("$PROJ")
  ( cd "$PROJ" && git init -q && git config user.email t@t && git config user.name t \
      && mkdir src && echo base > src/a.ts && git add -A && git commit -qm init >/dev/null )
  IDIR="$(instance_dir "$(slug_for "$PROJ")")"; mkdir -p "$IDIR/dispatches"
  printf '%s\n' "$(canon_path "$PROJ")" > "$IDIR/project"
  printf '%s\n' "$RID" > "$IDIR/run-id"
  printf '%s\n' "night-$RID" > "$IDIR/session"
  printf '%s\n' "$(git -C "$PROJ" rev-parse HEAD)" > "$IDIR/base-sha"
  jq -nc --arg t "$THREAD" '{id:"D-1", at:"2026-11-05T19:00:00Z", task:"Тендери: таблиця", thread_id:$t}' > "$IDIR/dispatch.json"
  if [ "${1:-}" = long ]; then
    piece plan "Документи" "Рішення" >/dev/null
    piece start -- "документи видно" >/dev/null
  fi
  echo "work $RANDOM" >> "$PROJ/src/a.ts"; git -C "$PROJ" commit -qam work
  jq -nc --arg r "$RID" --arg n "$RANDOM" '{result:"succeeded_changes", summary:("готово " + $n), run_id:$r, ts:"2026-11-05 21:00"}' > "$IDIR/outcome.json"
}
envelope(){   # $1=seq $2=message id $3=relation $4=text [$5=thread] [$6=run id]
  jq -nc --arg s "$1" --arg id "$2" --arg rel "$3" --arg m "$4" --arg t "${5:-$THREAD}" --arg rid "${6:-$RID}" \
    '{seq:$s, at:"2026-11-05T21:54:00Z", pipeline:"plain", intent:"conversation", message:$m,
      relation:$rel, revision:2, thread_id:$t, message_id:$id, run_id:$rid}' > "$(pending_dir "$IDIR")/$1-$2.json"
}
rungate(){
  rm -f "$CALLED"
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$1" "$TR" "$PROJ" \
    | ORCHESTRATOR_RUN_ID="$RID" SUPERVISOR_VERIFIER_ENABLED=0 PATH="$FAKE:$PATH" "$GATE" 2>/dev/null
}
reason(){ printf '%s' "$1" | jq -r '.reason // empty' 2>/dev/null; }
queued(){ ls "$(pending_dir "$IDIR")" 2>/dev/null | grep -c '\.json$'; }

echo "===== an ordinary run: a follow-up arrives at the first stop, prepared, before any review ====="
mkcase
envelope 00000007 msg-usd continue "Ціни в доларах і сортування колонок"
out="$(rungate s1)"
check "the stop is blocked with his words"   'reason "$out" | grep -q "Ціни в доларах і сортування колонок"'
check "prepared by the pipeline (composed)"  '[ -s "$(ls -d "$IDIR"/messages/*msg-usd*/ 2>/dev/null | head -1)composed.txt" ]'
check "no review against the old task"       '[ ! -f "$CALLED" ]'
check "nothing typed into the pane"          '[ ! -e "$SUPERVISOR_STATE_DIR/typed" ]'
check "the envelope is gone"                 '[ "$(queued)" = 0 ]'
check "marked delivered"                     'was_delivered "$IDIR" msg-usd'
check "the dispatch is now this follow-up"   '[ "$(jq -r .message_id "$IDIR/dispatch.json")" = msg-usd ] && [ "$(jq -r .relation "$IDIR/dispatch.json")" = continue ]'
check "the old outcome no longer stands"     '[ ! -e "$IDIR/outcome.json" ] && [ -s "$IDIR/outcome.before-followup.json" ]'
check "locks released"                       '[ ! -d "$IDIR/pipeline.lock" ] && [ ! -d "$IDIR/delivery.lock" ]'
check "the run view says it was delivered"   'grep -q "\"delivered\"" "$IDIR/run-events.jsonl"'

echo "===== the next review is told about it ====="
echo "more $RANDOM" >> "$PROJ/src/a.ts"; git -C "$PROJ" commit -qam usd
jq -nc --arg r "$RID" '{result:"succeeded_changes", summary:"долари й сортування", run_id:$r, ts:"2026-11-05 22:30"}' > "$IDIR/outcome.json"
rungate s2 >/dev/null
check "reviewed"                             '[ -f "$CALLED" ]'
check "the prompt carries the follow-up"     'grep -q "Ціни в доларах і сортування колонок" "$CALLED"'

echo "===== a long project: the same, at the stop between rounds ====="
mkcase long
envelope 00000008 msg-long continue "Колонки сортувати за датою"
out="$(rungate s1l)"
check "handed over in a long project too"    'reason "$out" | grep -q "Колонки сортувати за датою" && was_delivered "$IDIR" msg-long'
check "the plan is kept (a follow-up)"       '[ "$(jq -r ".pieces[0].state" "$IDIR/pieces.json" 2>/dev/null)" = open ]'

echo "===== a new task is not mixed in, and stops the follow-ups behind it ====="
mkcase
envelope 00000001 msg-b new "Нова задача: перероби дизайн"
envelope 00000002 msg-c continue "до нової задачі"
out="$(rungate s3)"
check "not handed over at the stop"          '! was_delivered "$IDIR" msg-b && ! was_delivered "$IDIR" msg-c && [ "$(queued)" = 2 ]'
check "the stop is reviewed as usual"        '[ -f "$CALLED" ]'

echo "===== taken back, another run, another thread: left to the pump ====="
mkcase
envelope 00000001 msg-x continue "передумав"
cancel_message "$IDIR" msg-x
rungate s5 >/dev/null
check "a cancelled one is not delivered"     '! was_delivered "$IDIR" msg-x && [ "$(queued)" = 1 ]'
mkcase
envelope 00000001 msg-y continue "для іншого прогону" "$THREAD" "another-run"
rungate s6 >/dev/null
check "another run's one is not delivered"   '! was_delivered "$IDIR" msg-y'
mkcase
envelope 00000001 msg-z continue "інша нитка" "thread-other"
rungate s7 >/dev/null
check "another thread's one is not delivered" '! was_delivered "$IDIR" msg-z'

echo "===== the pipeline is already at work: hands off, no waiting ====="
mkcase
envelope 00000001 msg-l continue "поки пайплайн тримає замок"
mkdir -p "$IDIR/pipeline.lock"; sleep 300 & holder=$!; printf '%s\n' "$holder" > "$IDIR/pipeline.lock/pid"
t0=$(date +%s); rungate s8 >/dev/null; t1=$(date +%s)
check "not delivered while the lock is held" '! was_delivered "$IDIR" msg-l && [ "$(queued)" = 1 ]'
check "the stop did not wait for the lock"   '[ $((t1 - t0)) -lt 20 ]'
check "and the holder's lock is untouched"   '[ "$(cat "$IDIR/pipeline.lock/pid")" = "$holder" ]'
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; rm -rf "$IDIR/pipeline.lock"

echo "===== a long project yields to a new task at the end of the piece ====="
mkcase long
envelope 00000009 msg-scope new "Нова задача: автоматичний go/no-go"
out="$(rungate s9)"
check "the piece is accepted"                '[ "$(jq -r ".pieces[0].state" "$IDIR/pieces.json")" = accepted ]'
check "the next piece is not opened"         '! reason "$out" | grep -q "Наступний за планом"'
check "the turn ends (no block)"             '[ -z "$(reason "$out")" ]'
check "his new task waits for the pump"      '[ "$(queued)" = 1 ]'

echo "===== the pipeline does not prepare what left the queue while it waited ====="
mkcase
envelope 00000004 msg-p continue "двічі не можна"
ENV="$(pending_dir "$IDIR")/00000004-msg-p.json"
mkdir -p "$IDIR/pipeline.lock"; sleep 300 & holder=$!; printf '%s\n' "$holder" > "$IDIR/pipeline.lock/pid"
( SUPERVISOR_PIPELINE_LOCK_WAIT=30 bash "$ROOT/bin/pipeline.sh" "$IDIR" "$ENV" >/dev/null 2>&1; echo $? > "$IDIR/pipe.rc" ) &
sleep 2
rm -f "$ENV"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; rm -rf "$IDIR/pipeline.lock"
for _ in $(seq 1 30); do [ -s "$IDIR/pipe.rc" ] && break; sleep 1; done
check "the pipeline stops with 8"            '[ "$(cat "$IDIR/pipe.rc" 2>/dev/null)" = 8 ]'
check "and wrote no dispatch over it"        '[ "$(jq -r .id "$IDIR/dispatch.json")" = D-1 ]'

echo
echo "stop delivery: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
