#!/bin/bash
# A review that converges instead of going round for a day (a server task, Nov 2026: 14 hours, two
# attempts, a 43-minute suite before every round). Pinned:
#   • REACH: a blocking item the reviewer marks rare is advisory — it neither blocks nor joins the ledger
#   • progress is the open count going down: closing one id while a fix brings a new blocker is not
#     progress, and two such rounds park the run, saying that every fix opens a new blocker
#   • [spec_conflict] parks the run with a question for the task's author (needs_input), the worker
#     gets no FAIL
#   • a task keeps one ledger across attempts: a continuation is a fix check of the same ids, an older
#     run-keyed ledger is taken over, the brief lists what is open
#   • a stop closes the attempt on the task record with the commits it left
#   • `add-check --final` runs once, after the review passes; a failure there sends the work back
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SUPERVISOR_STATE_DIR="$(mktemp -d)"
. "$ROOT/bin/supervisor-lib.sh"
GATE="$ROOT/hooks/review-gate.sh"
LEDGER="$ROOT/bin/lib/review-ledger.py"
export SUPERVISOR_CODEX_USAGE_CMD="/usr/bin/true"
export CODEX_SESSIONS_DIR="$(mktemp -d)"
unset SUPERVISOR_REVIEW_TEAM SUPERVISOR_PROFILE SUPERVISOR_REPORT_LANGUAGE
export ROOT SUPERVISOR_MAX_REMEDIATIONS=4 SUPERVISOR_MAX_ROUNDS=5 SUPERVISOR_MAX_ROUNDS_HARD=20 SUPERVISOR_STALL_LIMIT=2

pass=0; fail=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
no(){ echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

FAKE="$(mktemp -d)"; export FAKE CALLS="$FAKE/calls"
# A Codex that answers with the text in $FAKE/team (a member of the team) or $FAKE/single.
cat > "$FAKE/codex" <<'EOF'
#!/bin/bash
if [ "${1:-}" = login ]; then echo "Logged in using ChatGPT"; exit 0; fi
p="${@: -1}"; [ "$p" = - ] && p="$(cat)"
case "$p" in
  *"Prioritize requirements and business correctness"*|*"Prioritize security and data integrity"*|*"Prioritize state transitions and integration"*) role=team ;;
  *) role=single ;;
esac
echo "$role" >> "$CALLS"
printf '%s' "$p" > "$CALLS.$role.prompt"
cat "$FAKE/$role"
exit 0
EOF
chmod +x "$FAKE/codex"
answer(){ printf '%s\n' "$2" > "$FAKE/$1"; }
TR="$(mktemp)"; printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"text","text":"готово"}]}}' > "$TR"
REPOS=()
cleanup(){ rm -rf "$SUPERVISOR_STATE_DIR" "$FAKE" "$TR" "$CODEX_SESSIONS_DIR" ${REPOS[@]+"${REPOS[@]}"}; }
[ -n "${KEEP:-}" ] && echo "state: $SUPERVISOR_STATE_DIR" || trap cleanup EXIT

mkcase(){   # [$1=task id]
  RID="conv-run-$RANDOM$RANDOM"
  PROJ="$(mktemp -d)"; REPOS+=("$PROJ")
  ( cd "$PROJ" && git init -q && git config user.email t@t && git config user.name t \
      && mkdir src && echo base > src/a.ts && git add -A && git commit -qm init >/dev/null )
  IDIR="$(instance_dir "$(slug_for "$PROJ")")"; mkdir -p "$IDIR"
  printf '%s\n' "$(canon_path "$PROJ")" > "$IDIR/project"
  printf '%s\n' "$RID" > "$IDIR/run-id"
  printf '%s\n' "$(git -C "$PROJ" rev-parse HEAD)" > "$IDIR/base-sha"
  work
  if [ -n "${1:-}" ]; then
    TID="$1"
    printf '%s\n' "$TID" > "$IDIR/task-id"
    task_create "$TID" "$PROJ" youtrack someone "Add the record model. every role can still open the form." "" ""
    attempt initial
  fi
  rm -f "$CALLS" "$CALLS".*
}
work(){ echo "work $RANDOM" >> "$PROJ/src/a.ts"; git -C "$PROJ" commit -qam work
        jq -nc --arg r "$RID" '{result:"succeeded_changes", summary:"готово", run_id:$r, ts:"2026-11-23 12:00"}' > "$IDIR/outcome.json"; }
attempt(){   # $1=initial|continue — a dispatch record and the attempt on the task
  DID="d-$RANDOM$RANDOM"
  jq -nc --arg d "$DID" '{id:$d, task:"Add the record model"}' > "$IDIR/dispatch.json"
  task_attempt_begin "$TID" "$IDIR" "$DID" "$1"
}
GATE_OUT=""
rungate(){
  GATE_OUT="$(printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "s-$RANDOM" "$TR" "$PROJ" \
    | ORCHESTRATOR_RUN_ID="$RID" SUPERVISOR_VERIFIER_ENABLED="${VERIFIER:-0}" PATH="$FAKE:$PATH" "$GATE" 2>/dev/null)"
}
done_is(){ [ "$(cat "$IDIR/done" 2>/dev/null)" = "$1" ]; }
blocked(){ printf '%s' "$GATE_OUT" | grep -q '"decision"'; }
calls(){ grep -c "^$1\$" "$CALLS" 2>/dev/null || true; }
team_on(){ export SUPERVISOR_REVIEW_TEAM="contract security state"; }

echo "===== the ledger: REACH and net progress ====="
T="$(mktemp -d)"; REPOS+=("$T")
printf '%s\n' "STATE: COMPLETE" "VERDICT: FAIL" \
  "1. [regression_from_patch] a.py — a caller that catches AccessError and continues REACH: rare" \
  "2. [regression_from_patch] a.py — the form no longer opens REACH: ordinary" \
  "3. [acceptance_failure] **REACH:** Rare — seed renamed then recreated" > "$T/ans"
python3 "$LEDGER" reach "$T/ans" > "$T/out"
check "rare is re-tagged [related_improvement]"     'grep -q "^1. \[related_improvement\] a.py — a caller" "$T/out" && grep -q "^3. \[related_improvement\]" "$T/out"'
check "ordinary keeps its tag"                      'grep -q "^2. \[regression_from_patch\] a.py — the form no longer opens" "$T/out"'
python3 "$LEDGER" init "$T/l" "$T/ans" "[]" one >/dev/null
check "only the ordinary item joins the ledger"     '[ "$(python3 "$LEDGER" open "$T/l" | cut -d: -f1 | tr "\n" " ")" = "T1 " ]'
printf '%s\n' "1. [regression_from_patch] x — one REACH: ordinary" "2. [acceptance_failure] y — two REACH: ordinary" > "$T/a1"
python3 "$LEDGER" init "$T/m" "$T/a1" "[]" one >/dev/null
printf '%s\n' "STATE: COMPLETE" "VERDICT: FAIL" "T1: FIXED" "T2: OPEN — still" "1. [regression_from_patch] z — the fix broke the list REACH: ordinary" > "$T/a2"
r2="$(python3 "$LEDGER" apply "$T/m" "$T/a2" "[]")"
check "an id closed and a new blocker: no progress" '[ "$(printf "%s" "$r2" | jq .stall)" = 1 ] && [ "$(printf "%s" "$r2" | jq .churn)" = 1 ]'
printf '%s\n' "STATE: COMPLETE" "VERDICT: FAIL" "T2: OPEN — still" "N1: FIXED" "1. [regression_from_patch] w — the guard leaks names REACH: ordinary" > "$T/a3"
r3="$(python3 "$LEDGER" apply "$T/m" "$T/a3" "[]")"
check "again: stall 2, churn 2"                     '[ "$(printf "%s" "$r3" | jq .stall)" = 2 ] && [ "$(printf "%s" "$r3" | jq .churn)" = 2 ]'
printf '%s\n' "STATE: COMPLETE" "VERDICT: FAIL" "T2: FIXED" "N2: OPEN — still" > "$T/a4"
r4="$(python3 "$LEDGER" apply "$T/m" "$T/a4" "[]")"
check "fewer open is progress again"                '[ "$(printf "%s" "$r4" | jq .stall)" = 0 ] && [ "$(printf "%s" "$r4" | jq .churn)" = 0 ]'
printf '%s\n' "1. [spec_conflict] QUOTE: \"no migration\" — add one" "2. [acceptance_failure] q — real REACH: ordinary" > "$T/a5"
python3 "$LEDGER" init "$T/s" "$T/a5" "[]" one >/dev/null
check "[spec_conflict] is not a ledger item"        '[ "$(python3 "$LEDGER" count "$T/s")" = 1 ]'

echo "===== a rare regression in a fix check does not block ====="
team_on; mkcase
answer team "STATE: COMPLETE
VERDICT: FAIL
1. [acceptance_failure] src/a.ts — the empty state is missing REACH: ordinary"
rungate
check "the team's FAIL starts the ledger"           'blocked && [ "$(calls team)" = 3 ]'
work
# The three members said the same thing: T1..T3, one defect.
answer single "STATE: COMPLETE
VERDICT: FAIL
DUPLICATES: NAMED
T1: FIXED
T2: SAME AS T1
T3: SAME AS T1
1. [regression_from_patch] src/a.ts — a caller that catches the error and continues REACH: rare"
rungate
check "the fix check asks for REACH"                'grep -q "REACH: rare" "$CALLS.single.prompt"'
check "rare only: the work is accepted"             'done_is passed && ! blocked'

echo "===== every fix opens a new blocker: parked after two rounds ====="
mkcase
answer team "STATE: COMPLETE
VERDICT: FAIL
1. [acceptance_failure] src/a.ts — one REACH: ordinary
2. [acceptance_failure] src/a.ts — two REACH: ordinary"
rungate; work
answer single "STATE: COMPLETE
VERDICT: FAIL
DUPLICATES: NONE
T1: FIXED
T2: OPEN — still
1. [regression_from_patch] src/a.ts — the fix broke the list REACH: ordinary"
rungate
check "round 2 goes back"                           'blocked && ! done_is needs-user'
check "and does not promise rounds the stall rule would not give" 'printf "%s" "$GATE_OUT" | jq -r .reason | grep -q "зупинюсь, якщо 2 раунди поспіль" && ! printf "%s" "$GATE_OUT" | jq -r .reason | grep -q "можливих"'
work
answer single "STATE: COMPLETE
VERDICT: FAIL
T2: OPEN — still
N1: FIXED
1. [regression_from_patch] src/a.ts — the new guard leaks names REACH: ordinary"
rungate
check "round 3: parked for a person"                'done_is needs-user && ! blocked'
check "saying every fix opens a new blocker"        'grep -q "churn 2" "$SUPERVISOR_STATE_DIR/supervisor.log" && grep -rq "Кожне виправлення відкриває новий блокер" "$IDIR" "$SUPERVISOR_STATE_DIR" 2>/dev/null'
unset SUPERVISOR_REVIEW_TEAM

echo "===== the task's own decision disputed: a question for its author ====="
mkcase "PRJ-$RANDOM"
answer single "STATE: COMPLETE
VERDICT: FAIL
1. [spec_conflict] QUOTE: \"every role can still open the form\" — a reader sees the record's name; I would hide it
2. [acceptance_failure] src/a.ts — record rules are not applied REACH: ordinary"
rungate
check "the worker gets no FAIL"                     '! blocked && done_is needs-user'
check "the task waits for an answer"                '[ "$(task_get "$TID" .state)" = needs_input ] && [ "$(task_get "$TID" .state_reason)" = spec_conflict ]'
check "the question quotes the task"                'task_get "$TID" .question.text | grep -q "every role can still open the form" && [ "$(task_get "$TID" ".question.options | length")" = 2 ]'
check "the record's question file is gone"          '[ ! -e "$IDIR/gate-question.json" ]'

echo "===== a task keeps its ledger across attempts ====="
team_on; mkcase "PRJ-$RANDOM"
answer team "STATE: COMPLETE
VERDICT: FAIL
1. [acceptance_failure] src/a.ts — upgrade on a base with requests is not proven REACH: ordinary"
rungate
TLEDGER="$SUPERVISOR_STATE_DIR/review-ledger-$(task_key "$TID")"
check "the ledger is the task's"                    '[ -s "$TLEDGER" ] && [ ! -e "$SUPERVISOR_STATE_DIR/review-ledger-$RID" ]'
# Stopped from outside before the next verdict, as a bridge's timeout does.
task_on_stop "$IDIR"
check "the stop closes the attempt"                 '[ "$(task_get "$TID" ".attempts[-1].result")" = stopped ] && [ -n "$(task_get "$TID" ".attempts[-1].ended_at")" ]'
check "with the commits it left"                    '[ "$(task_get "$TID" ".repos | length")" -ge 1 ] && [ -n "$(task_get "$TID" ".repos[0].head_sha // .repos[0].sha // .repos[0].path")" ]'
check "and the task state is the bridge's to set"   '[ "$(task_get "$TID" .state)" = running ]'
check "night-shift stop does it"                    'grep -q "task_on_stop \"\$idir\"" "$ROOT/bin/night-shift.sh"'
BRIEF="$(task_brief "$TID" "/continue" youtrack someone)"
check "the continuation brief lists the open ids"   'printf "%s" "$BRIEF" | grep -q "Що лишилось відкритим" && printf "%s" "$BRIEF" | grep -q "^T1: .*upgrade on a base"'
check "and where the work is"                       'printf "%s" "$BRIEF" | grep -A2 "Де робота зараз" | grep -q "$(basename "$PROJ")"'
# The continuation: a new run of the same task.
RID="conv-run-$RANDOM$RANDOM"; printf '%s\n' "$RID" > "$IDIR/run-id"; attempt continue; work; rm -f "$CALLS" "$CALLS".*
answer single "STATE: COMPLETE
VERDICT: PASS
DUPLICATES: NAMED
T1: FIXED
T2: SAME AS T1
T3: SAME AS T1"
rungate
check "the continuation is a fix check, not the team again" '[ "$(calls team)" = 0 ] && [ "$(calls single)" = 1 ] && grep -q "FIX CHECK" "$CALLS.single.prompt" && grep -q "^T1: .*upgrade on a base" "$CALLS.single.prompt"'
check "and passes on the same id"                   'done_is passed && [ ! -e "$TLEDGER" ]'

echo "===== an older attempt's run ledger is taken over ====="
mkcase "PRJ-$RANDOM"
OLD="$RID"; printf '%s\n' "1. [acceptance_failure] src/a.ts — N4 left open REACH: ordinary" > "$FAKE/old"
python3 "$LEDGER" init "$SUPERVISOR_STATE_DIR/review-ledger-$OLD" "$FAKE/old" "[]" one >/dev/null
jq '.stall = 2 | .churn = 2' "$SUPERVISOR_STATE_DIR/review-ledger-$OLD" > "$FAKE/l.tmp" && mv "$FAKE/l.tmp" "$SUPERVISOR_STATE_DIR/review-ledger-$OLD"
RID="conv-run-$RANDOM$RANDOM"; printf '%s\n' "$RID" > "$IDIR/run-id"; attempt continue; work; rm -f "$CALLS" "$CALLS".*
answer single "STATE: COMPLETE
VERDICT: FAIL
T1: OPEN — still there"
rungate
check "a new attempt starts its no-progress count again" '[ "$(jq .stall "$SUPERVISOR_STATE_DIR/review-ledger-$(task_key "$TID")")" = 1 ] && [ "$(jq -r .run "$SUPERVISOR_STATE_DIR/review-ledger-$(task_key "$TID")")" = "$RID" ]'
check "the old run's ledger became the task's"      '[ ! -e "$SUPERVISOR_STATE_DIR/review-ledger-$OLD" ] && [ -s "$SUPERVISOR_STATE_DIR/review-ledger-$(task_key "$TID")" ]'
check "and the review checked its id"               '[ "$(calls team)" = 0 ] && grep -q "N4 left open" "$CALLS.single.prompt"'
unset SUPERVISOR_REVIEW_TEAM

echo "===== add-check --final: once, after the review passes ====="
mkcase
CNT="$FAKE/count"; : > "$CNT.quick"; : > "$CNT.heavy"
( cd "$PROJ" && IDIR="$IDIR" "$ROOT/bin/add-check.sh" "quick" -- bash -c "echo q >> '$CNT.quick'" >/dev/null \
  && IDIR="$IDIR" "$ROOT/bin/add-check.sh" --final --timeout 60 "full suite" -- bash -c "echo h >> '$CNT.heavy'; [ ! -e '$FAKE/heavy-fails' ]" >/dev/null )
check "registered as final"                         'jq -s -e "map(select(.criterion == \"full suite\"))[0].final == true" "$IDIR/checks.jsonl" >/dev/null'
check "the list says so"                            '( cd "$PROJ" && IDIR="$IDIR" "$ROOT/bin/add-check.sh" --list ) | grep -q "фінальна"'
answer single "STATE: COMPLETE
VERDICT: FAIL
1. [acceptance_failure] src/a.ts — not yet REACH: ordinary"
export VERIFIER=1
for k in 1 2 3; do rungate; work; done
check "three FAIL rounds: quick ran 3 times, the heavy one never" '[ "$(grep -c . "$CNT.quick")" = 3 ] && [ "$(grep -c . "$CNT.heavy")" = 0 ]'
check "the reviewer is told it is pending"          'grep -q "FINAL CHECKS (heavy" "$CALLS.single.prompt" && grep -q "full suite" "$CALLS.single.prompt"'
touch "$FAKE/heavy-fails"
answer single "STATE: COMPLETE
VERDICT: PASS"
rungate
check "a PASS runs it; its failure sends the work back" '[ "$(grep -c . "$CNT.heavy")" = 1 ] && blocked && ! done_is passed && printf "%s" "$GATE_OUT" | jq -r .reason | grep -q "Final check not passed: full suite"'
rm -f "$FAKE/heavy-fails"; work
rungate
check "the next PASS runs it once more and is accepted" '[ "$(grep -c . "$CNT.heavy")" = 2 ] && [ "$(grep -c . "$CNT.quick")" = 5 ] && done_is passed'
unset VERIFIER

echo
echo "review converges: $pass passed, $fail failed"
[ "$fail" = 0 ]
