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
#   • every way to acceptance goes through it (an advisory-only FAIL too); nothing readable parks for a
#     person, never debt; a long check repeats its step; an edit while it runs is not accepted
#   • a report's review: advisory and rare items pass, an ordinary one goes back, [spec_conflict] asks
#   • a stopped or superseded attempt is never settled by a late verdict
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

echo "===== every way to acceptance goes through the final checks ====="
mkcase
( cd "$PROJ" && IDIR="$IDIR" "$ROOT/bin/add-check.sh" --final "full suite" -- bash -c "echo heavy; exit 3" >/dev/null )
answer single "STATE: COMPLETE
VERDICT: FAIL
1. [acceptance_failure] src/a.ts — a caller that catches it and goes on REACH: rare"
VERIFIER=1 rungate
check "an advisory-only FAIL runs the final check, and its failure blocks" 'blocked && ! done_is passed && printf "%s" "$GATE_OUT" | jq -r .reason | grep -q "Final check not passed: full suite"'
check "it goes back as a defect, never as debt"     '! done_is debt && printf "%s" "$GATE_OUT" | jq -r .reason | grep -q "\[acceptance_failure\] Final check"'

mkcase
( cd "$PROJ" && IDIR="$IDIR" "$ROOT/bin/add-check.sh" --final "full suite" -- /nonexistent/bulava-check >/dev/null 2>&1 )
answer single "STATE: COMPLETE
VERDICT: PASS"
VERIFIER=1 rungate
check "a final check that cannot start is not accepted, and not debt" 'done_is needs-user && ! blocked'

mkcase
( cd "$PROJ" && IDIR="$IDIR" "$ROOT/bin/add-check.sh" --final --timeout 30 "slow suite" -- bash -c "sleep 4" >/dev/null )
answer single "STATE: COMPLETE
VERDICT: PASS"
SUPERVISOR_FINAL_HEARTBEAT=1 SUPERVISOR_FINAL_POLL=1 VERIFIER=1 rungate
check "a long final check says it is still running" '[ "$(jq -c "select(.stage == \"gate.verify\" and .state == \"running\" and .heartbeat == true)" "$IDIR/run-events.jsonl" 2>/dev/null | grep -c .)" -ge 2 ] && done_is passed'

mkcase
( cd "$PROJ" && IDIR="$IDIR" "$ROOT/bin/add-check.sh" --final "full suite" -- bash -c "echo edited >> src/a.ts" >/dev/null )
answer single "STATE: COMPLETE
VERDICT: PASS"
VERIFIER=1 rungate
check "an uncommitted edit during the final checks: not accepted" 'blocked && ! done_is passed && printf "%s" "$GATE_OUT" | jq -r .reason | grep -q "незакомічена правка"'

echo "===== a report's review: advisory items pass, the task's decisions go to its author ====="
report_case(){   # [$1=task id]
  mkcase ${1:+"$1"}
  : > "$IDIR/direct-chat"
  # A research run changed no code: the base is where the repository is now.
  printf 'artifacts/\n' > "$PROJ/.gitignore"
  git -C "$PROJ" add .gitignore && git -C "$PROJ" commit -qm ignore && git -C "$PROJ" rev-parse HEAD > "$IDIR/base-sha"
  jq -nc --arg d "${DID:-d-r}" '{id:$d, task:"Research the market. Use only 2025 figures.", pipeline:"my-flow",
    pipeline_gates:{review:false, reportReview:true, research:true, reportMaxRounds:5}}' > "$IDIR/dispatch.json"
  mkdir -p "$PROJ/artifacts"; printf '# Report\nThe market grew 40%% in 2025 ([source](https://example.org/m)).\n' > "$PROJ/artifacts/report.md"
  jq -nc --arg r "$RID" '{result:"succeeded_research", summary:"Done: artifacts/report.md", run_id:$r, ts:"2026-11-24 10:00"}' > "$IDIR/outcome.json"
}
report_case
answer single "STATE: COMPLETE
VERDICT: FAIL
1. [acceptance_failure] \"grew 40%\" — a reader who converts currencies would get 39% REACH: rare
2. [related_improvement] one more source would help REACH: ordinary"
rungate
check "a report with only rare and advisory items is accepted" 'done_is passed && ! blocked && grep -q "gate.reportReview" "$IDIR/run-events.jsonl"'
check "the first reading asks for tags and REACH"   'grep -q "REACH: rare does not hold the report back" "$CALLS.single.prompt" && grep -q "\[spec_conflict\]" "$CALLS.single.prompt"'

report_case
answer single "STATE: COMPLETE
VERDICT: FAIL
1. [acceptance_failure] \"grew 40%\" — the source says 14% REACH: ordinary"
rungate
check "an ordinary defect sends the report back"    'blocked && ! done_is passed'
answer single "STATE: COMPLETE
VERDICT: FAIL
T1: FIXED
1. [regression_from_patch] the new figure is rounded differently REACH: rare"
rungate
check "a fix check with every id closed and only a rare item passes" 'done_is passed && ! blocked'

report_case "PRJ-$RANDOM"
answer single "STATE: COMPLETE
VERDICT: FAIL
1. [spec_conflict] QUOTE: \"Use only 2025 figures\" — 2026 forecasts exist and would make it stronger
2. [related_improvement] wording REACH: ordinary"
rungate
check "a report's [spec_conflict] parks it for the task's author" '! blocked && done_is needs-user && [ "$(task_get "$TID" .state)" = needs_input ] && task_get "$TID" .question.text | grep -q "Use only 2025 figures"'

echo "===== a late verdict and the attempt record ====="
mkcase "PRJ-$RANDOM"
task_on_stop "$IDIR"
answer single "STATE: COMPLETE
VERDICT: PASS"
rungate
check "a PASS after the stop does not reopen the stopped attempt" '[ "$(task_get "$TID" ".attempts[-1].result")" = stopped ] && [ "$(task_get "$TID" .state)" = running ]'
check "it is recorded as stale"                     'grep -q "\"kind\":\"stale-verdict\"" "$(task_dir "$TID")/events.jsonl"'
# A continuation, then a second one before the first got its verdict.
RID="conv-run-$RANDOM$RANDOM"; printf '%s\n' "$RID" > "$IDIR/run-id"; attempt continue; OLD_DID="$DID"; OLD_RID="$RID"
RID="conv-run-$RANDOM$RANDOM"; printf '%s\n' "$RID" > "$IDIR/run-id"; attempt continue
check "two continuations leave one open attempt"    '[ "$(task_get "$TID" "[.attempts[] | select(.ended_at == null)] | length")" = 1 ] && [ "$(task_get "$TID" ".attempts[-2].result")" = superseded ]'
# The first continuation's verdict arrives late, from its own folder state.
LATE="$(mktemp -d)"; REPOS+=("$LATE"); cp -R "$IDIR/." "$LATE/"
printf '%s\n' "$OLD_RID" > "$LATE/run-id"; jq -nc --arg d "$OLD_DID" '{id:$d}' > "$LATE/dispatch.json"
task_on_terminal "$LATE" passed
check "the superseded attempt's verdict changes nothing" '[ "$(task_get "$TID" .state)" = running ] && [ -z "$(task_get "$TID" ".attempts[-1].ended_at")" ]'
# The check and the write are one step under the lock: a stop landing between them cannot be overwritten.
check "the attempt check is made under the task lock" 'sed -n "/^task_update_attempt()/,/^}/p" "$ROOT/bin/lib/tasks.sh" | awk "/_task_lock/{l=NR} /jq -e/{j=NR} END{exit !(l && j && l < j)}"'

echo "===== a /continue while the final checks run: the old gate writes nothing ====="
team_on; mkcase "PRJ-$RANDOM"
answer team "STATE: COMPLETE
VERDICT: FAIL
1. [acceptance_failure] src/a.ts — the empty state is missing REACH: ordinary"
rungate
TLEDGER="$SUPERVISOR_STATE_DIR/review-ledger-$(task_key "$TID")"
unset SUPERVISOR_REVIEW_TEAM; work
# The final check is where the next attempt arrives: the folder is given to it mid-check.
cat > "$FAKE/continue.sh" <<EOF2
#!/bin/bash
. "$ROOT/bin/supervisor-lib.sh" >/dev/null 2>&1
printf '%s\n' "conv-run-next" > "$IDIR/run-id"
jq -nc '{id:"d-next", task:"Add the record model"}' > "$IDIR/dispatch.json"
task_attempt_begin "$TID" "$IDIR" "d-next" continue
EOF2
chmod +x "$FAKE/continue.sh"
( cd "$PROJ" && IDIR="$IDIR" "$ROOT/bin/add-check.sh" --final "full suite" -- "$FAKE/continue.sh" >/dev/null )
answer single "STATE: COMPLETE
VERDICT: PASS
DUPLICATES: NAMED
T1: FIXED
T2: SAME AS T1
T3: SAME AS T1"
VERIFIER=1 rungate
check "the old gate's PASS settles nothing"          '[ "$(task_get "$TID" .state)" = running ] && [ "$(task_get "$TID" ".attempts[-1].dispatch_id")" = d-next ] && [ -z "$(task_get "$TID" ".attempts[-1].ended_at")" ]'
check "the attempt it was about is closed as superseded" '[ "$(task_get "$TID" ".attempts[-2].result")" = superseded ]'
# (The old gate answered the list while the folder was still its own; it is not cleared after.)
check "its review list is not cleared"               '[ -s "$TLEDGER" ]'
check "no done mark, no pass written in the folder"  '! done_is passed && grep -q "\"kind\":\"stale-verdict\"" "$(task_dir "$TID")/events.jsonl"'

echo "===== any acceptance waits for the final checks, debt included ====="
mkcase
( cd "$PROJ" && IDIR="$IDIR" "$ROOT/bin/add-check.sh" --final "full suite" -- bash -c "exit 0" >/dev/null )
# A tool failure alone is banked as debt; the final checks never ran in this round.
answer single "STATE: COMPLETE
VERDICT: FAIL
1. [harness_failure] the build tool crashed"
VERIFIER=1 rungate
check "a debt with a final check not run is not accepted" 'done_is needs-user && ! done_is debt'

echo "===== a repository the reviewer read that is gone: not accepted ====="
mkcase
( cd "$PROJ" && IDIR="$IDIR" "$ROOT/bin/add-check.sh" --final "full suite" -- bash -c "rm -rf .git" >/dev/null )
answer single "STATE: COMPLETE
VERDICT: PASS"
VERIFIER=1 rungate
check "a repository gone after the review blocks acceptance" '! done_is passed'

echo "===== a report goes through the final checks ====="
report_case
( cd "$PROJ" && IDIR="$IDIR" "$ROOT/bin/add-check.sh" --final "report data check" -- bash -c "echo stale data; exit 2" >/dev/null )
answer single "STATE: COMPLETE
VERDICT: PASS"
rungate
check "a report PASS with a failing final check goes back" 'blocked && ! done_is passed && printf "%s" "$GATE_OUT" | jq -r .reason | grep -q "Final check not passed: report data check"'

echo "===== an advisory-only FAIL in a scoped run is accepted too ====="
mkcase
jq -nc '{schema:1, task_id:"t", mode:"scoped", objective:"Add the empty state", acceptance:["the empty state shows"], write_paths:["src/"]}' > "$IDIR/runspec.json"
answer single "STATE: COMPLETE
VERDICT: FAIL
1. [related_improvement] src/a.ts — a nicer name REACH: ordinary"
rungate
check "scoped: advisory only, accepted"              'done_is passed && ! blocked && grep -q "advisory-only FAIL taken as PASS" "$SUPERVISOR_STATE_DIR/supervisor.log" && tail -3 "$SUPERVISOR_STATE_DIR/supervisor.log" | grep -q "bounded PASS"'

echo "===== a stop while the final checks run: nothing is published ====="
team_on; mkcase "PRJ-$RANDOM"
answer team "STATE: COMPLETE
VERDICT: FAIL
1. [acceptance_failure] src/a.ts — the empty state is missing REACH: ordinary"
rungate
TLEDGER="$SUPERVISOR_STATE_DIR/review-ledger-$(task_key "$TID")"
unset SUPERVISOR_REVIEW_TEAM; work
cat > "$FAKE/stop.sh" <<EOF2
#!/bin/bash
. "$ROOT/bin/supervisor-lib.sh" >/dev/null 2>&1
task_on_stop "$IDIR"
EOF2
chmod +x "$FAKE/stop.sh"
( cd "$PROJ" && IDIR="$IDIR" "$ROOT/bin/add-check.sh" --final "full suite" -- "$FAKE/stop.sh" >/dev/null )
rm -f "$IDIR/review.json"
answer single "STATE: COMPLETE
VERDICT: PASS
DUPLICATES: NAMED
T1: FIXED
T2: SAME AS T1
T3: SAME AS T1"
VERIFIER=1 rungate
check "a stop during the final checks: no pass is written" '! done_is passed && ! jq -e ".disposition == \"passed\"" "$IDIR/review.json" >/dev/null 2>&1'
check "the stopped attempt stays stopped"            '[ "$(task_get "$TID" ".attempts[-1].result")" = stopped ]'
check "and its review list is kept for the next attempt" '[ -s "$TLEDGER" ]'

echo "===== the beat stops with the attempt ====="
mkcase "PRJ-$RANDOM"
cat > "$FAKE/continue-slow.sh" <<EOF2
#!/bin/bash
. "$ROOT/bin/supervisor-lib.sh" >/dev/null 2>&1
printf '%s\n' "conv-run-after" > "$IDIR/run-id"
jq -nc '{id:"d-after", task:"Add the record model"}' > "$IDIR/dispatch.json"
task_attempt_begin "$TID" "$IDIR" "d-after" continue
sleep 8
EOF2
chmod +x "$FAKE/continue-slow.sh"
( cd "$PROJ" && IDIR="$IDIR" "$ROOT/bin/add-check.sh" --final --timeout 60 "slow suite" -- "$FAKE/continue-slow.sh" >/dev/null )
answer single "STATE: COMPLETE
VERDICT: PASS"
_t0=$(date +%s)
SUPERVISOR_FINAL_HEARTBEAT=1 SUPERVISOR_FINAL_POLL=1 VERIFIER=1 rungate
_t1=$(date +%s)
check "the old gate stops its checks once the attempt is gone" '[ $((_t1 - _t0)) -lt 8 ] && ! done_is passed'
check "no beat is written for the new attempt"       '[ "$(jq -c "select(.dispatch_id == \"d-after\" and .heartbeat == true)" "$IDIR/run-events.jsonl" 2>/dev/null | grep -c .)" = 0 ]'
check "the old gate's events carry its own attempt"  '[ "$(jq -r "select(.stage == \"gate.verify\") | .dispatch_id" "$IDIR/run-events.jsonl" | sort -u | grep -c d-after)" = 0 ]'

echo "===== a final check whose log is gone is not a pass ====="
mkcase
( cd "$PROJ" && IDIR="$IDIR" "$ROOT/bin/add-check.sh" --final "full suite" -- bash -c 'rm -f "$0"/evidence/*-final/full-suite.log; exit 0' "$IDIR" >/dev/null )
answer single "STATE: COMPLETE
VERDICT: PASS"
VERIFIER=1 rungate
check "pass and exit 0 without its log: parked, not accepted" 'done_is needs-user && ! blocked'

echo "===== a report: an edit during its final checks, and the at-limit acceptance ====="
report_case
( cd "$PROJ" && IDIR="$IDIR" "$ROOT/bin/add-check.sh" --final "report data check" -- bash -c "echo edited >> src/a.ts" >/dev/null )
answer single "STATE: COMPLETE
VERDICT: PASS"
rungate
check "an edit to a tracked file during a report's final check: not accepted" 'blocked && ! done_is passed && printf "%s" "$GATE_OUT" | jq -r .reason | grep -q "незакомічена правка"'

report_case
jq '.pipeline_gates.reportMaxRounds = 1 | .pipeline_gates.reportAtLimit = "accept"' "$IDIR/dispatch.json" > "$FAKE/d.tmp" && mv "$FAKE/d.tmp" "$IDIR/dispatch.json"
( cd "$PROJ" && IDIR="$IDIR" "$ROOT/bin/add-check.sh" --final "report data check" -- bash -c "exit 4" >/dev/null )
answer single "STATE: COMPLETE
VERDICT: FAIL
1. [acceptance_failure] \"grew 40%\" — the source says 14% REACH: ordinary"
rungate
check "at its limit, a failing final check is not accepted with notes" 'done_is needs-user && ! done_is passed && [ -s "$SUPERVISOR_STATE_DIR/report-ledger-$RID" ]'

echo "===== the export test's own skip is a skip ====="
check "it says SKIP, so the cache never keeps it"    'grep -q "echo \"SKIP: already running from an exported tree" "$ROOT/tests/test-export-suite.sh" && printf "SKIP: already running from an exported tree\n" > "$FAKE/skip.log" && . "$ROOT/bin/lib/test-cache.sh" && test_cache_skipped "$FAKE/skip.log"'

echo
echo "review converges: $pass passed, $fail failed"
[ "$fail" = 0 ]
