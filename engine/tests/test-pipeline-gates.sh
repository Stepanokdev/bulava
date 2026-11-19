#!/bin/bash
# The gates a built pipeline asks for — driven through the real Stop hook.
#
#   • the review's round limit comes from the pipeline (within the engine's ceiling);
#   • a REQUIRED skill is checked in the session's own transcript: no successful Skill call after the
#     task began → the work goes back once with the reason, a second miss parks for the director;
#     with the call present the work goes on to the ordinary review;
#   • a research pipeline's report is reviewed as a report: found in artifacts/, PASS accepts the run
#     (it is no longer "debt"), FAIL sends it back with the findings up to the pipeline's limit, and
#     a run that names no report is asked for one;
#   • the built-in flow (no pipeline gates) is untouched;
#   • every one of those steps leaves an event, signed with the message it belongs to.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SUPERVISOR_STATE_DIR="$(mktemp -d)"
. "$ROOT/bin/supervisor-lib.sh"
GATE="$ROOT/hooks/review-gate.sh"
export SUPERVISOR_CODEX_USAGE_CMD="/usr/bin/true"
export CODEX_SESSIONS_DIR="$(mktemp -d)"
RID="gates-test-run-id"

pass=0; fail=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
no(){ echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

FAKE="$(mktemp -d)"; CODEX_CALLED="$FAKE/called"; export CODEX_CALLED
cat > "$FAKE/codex" <<'EOF'
#!/bin/bash
if [ "${1:-}" = login ]; then echo "Logged in using ChatGPT"; exit 0; fi
prompt=""; for a in "$@"; do prompt="$a"; done
if [ "$prompt" = "-" ]; then prompt="$(cat)"; elif [ -p /dev/stdin ] || [ -f /dev/stdin ]; then _in="$(perl -e 'alarm 10; local $/; my $x = <STDIN>; print defined $x ? $x : ""')"; [ -n "$_in" ] && prompt="$_in"; fi   # the engine sends prompts on stdin
if printf '%s' "$prompt" | grep -q "RESEARCH REPORT"; then
  printf '%s' "$prompt" > "$CODEX_CALLED.report-prompt"
  [ -n "${FAKE_REPORT_GARBLED:-}" ] && { echo "Я подумав і, здається, тут щось не так."; exit 0; }
  echo "STATE: COMPLETE"; echo "VERDICT: ${FAKE_REPORT_VERDICT:-PASS}"
  [ "${FAKE_REPORT_VERDICT:-PASS}" = FAIL ] && echo "1. «ринок зріс на 40%» — без джерела"
  exit 0
fi
if printf '%s' "$prompt" | grep -q "HANDOFF | BLOCKED"; then
  : > "$CODEX_CALLED"
  echo "STATE: ${FAKE_STATE:-COMPLETE}"; echo "VERDICT: ${FAKE_VERDICT:-PASS}"
  [ -n "${FAKE_FINDING:-}" ] && echo "1. ${FAKE_FINDING}"
  exit 0
fi
echo "VERDICT: PASS"
EOF
chmod +x "$FAKE/codex"

REPOS=()
cleanup(){ rm -rf "$SUPERVISOR_STATE_DIR" "$FAKE" "$CODEX_SESSIONS_DIR" ${REPOS[@]+"${REPOS[@]}"}; }
trap cleanup EXIT

NOW="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
mkcase(){  # $1 = pipeline gates json ('' = none)
  PROJ="$(mktemp -d)"; REPOS+=("$PROJ")
  ( cd "$PROJ" && git init -q && git config user.email t@t && git config user.name t \
      && printf 'artifacts/\n' > .gitignore && echo base > app.txt && git add -A && git commit -qm init >/dev/null )
  IDIR="$(instance_dir "$(slug_for "$PROJ")")"; mkdir -p "$IDIR"
  printf '%s\n' "$(canon_path "$PROJ")" > "$IDIR/project"
  printf '%s\n' "$RID" > "$IDIR/run-id"
  printf '%s\n' "$(git -C "$PROJ" rev-parse HEAD)" > "$IDIR/base-sha"
  : > "$IDIR/direct-chat"
  if [ -n "${1:-}" ]; then
    jq -nc --arg at "$NOW" --argjson g "$1" '{id:"disp-1", at:$at, task:"Зроби налаштування мови", message_id:"msg-1", pipeline:"my-flow", pipeline_gates:$g}' > "$IDIR/dispatch.json"
  else
    jq -nc --arg at "$NOW" '{id:"disp-1", at:$at, task:"Зроби налаштування мови", message_id:"msg-1", pipeline:"adaptive-peer"}' > "$IDIR/dispatch.json"
  fi
  TR="$PROJ.transcript.jsonl"; REPOS+=("$TR")
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"готово"}]}}' > "$TR"
  rm -f "$SUPERVISOR_STATE_DIR"/rounds-* "$SUPERVISOR_STATE_DIR"/skillmiss-* "$SUPERVISOR_STATE_DIR"/outcome-nudge-* 2>/dev/null || true
}
work(){ echo "worker $RANDOM" >> "$PROJ/app.txt"; }
skill_called(){  # $1 = skill name
  local t; t="$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')"
  printf '%s\n' "{\"type\":\"assistant\",\"timestamp\":\"$t\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_9\",\"name\":\"Skill\",\"input\":{\"skill\":\"$1\"}}]}}" >> "$TR"
  printf '%s\n' "{\"type\":\"user\",\"timestamp\":\"$t\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_9\",\"content\":\"loaded\"}]}}" >> "$TR"
}
outcome(){  # $1=result $2=summary
  jq -nc --arg r "$1" --arg s "${2:-}" --arg rid "$RID" --arg ts "$(date '+%F %T')" \
    '{schema:1, result:$r, summary:$s, ts:$ts, run_id:$rid, dispatch_id:"disp-1"}' > "$IDIR/outcome.json"
}
rungate(){
  rm -f "$CODEX_CALLED" "$CODEX_CALLED.report-prompt"
  rm -f "$IDIR/done" "$IDIR/done-digest" 2>/dev/null
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "${1:-s1}" "$TR" "$PROJ" \
    | ORCHESTRATOR_RUN_ID="$RID" SUPERVISOR_VERIFIER_ENABLED=0 PATH="$FAKE:$PATH" "$GATE"
}
done_is(){ [ "$(cat "$IDIR/done" 2>/dev/null)" = "$1" ]; }
ev(){ jq -c --arg s "$1" --arg st "$2" 'select(.stage == $s and .state == $st)' "$IDIR/run-events.jsonl" 2>/dev/null | head -1; }

echo "== the built-in flow is untouched =="
mkcase ""; work
out="$(rungate)"
check "a PASS still passes"                         'done_is passed'
check "the reviewer was the ordinary Codex review"   '[ -f "$CODEX_CALLED" ]'
check "and the chat sees it: review verified, run passed" '[ -n "$(ev gate.review verified)" ] && [ -n "$(ev run passed)" ]'
check "events carry the message they belong to"       '[ "$(jq -r "select(.stage==\"run\") | .message_id" "$IDIR/run-events.jsonl" | head -1)" = msg-1 ]'

echo "== a review that ends BLOCKED ends on the run view too =="
# It used to leave "Codex review · working" on screen under "work stopped": the gate closed the
# review step only on a pass, and a BLOCKED verdict parked the run with no word of why.
mkcase ""; work
out="$(FAKE_STATE=BLOCKED FAKE_VERDICT=N/A FAKE_FINDING="Потрібен доступ до production VPS для розгортання" rungate)"
check "parked for the director"                           'done_is needs-user'
check "the review step is closed as waiting for the director" '[ -n "$(ev gate.review waiting)" ]'
check "no review step is left running once the run ended" '[ "$(jq -r "select(.stage==\"gate.review\") | .state" "$IDIR/run-events.jsonl" | tail -1)" != running ]'
check "the reason the reviewer gave travels with the stop" 'ev run needs-user | jq -r .note | grep -q "production VPS"'
check "…on the review step too"                           'ev gate.review waiting | jq -r .note | grep -q "production VPS"'

echo "== the round limit comes from the pipeline =="
mkcase '{"review":true,"maxRounds":5,"requiredSkills":[]}'; work
out="$(FAKE_VERDICT=FAIL FAKE_FINDING="[acceptance_failure] мова не зберігається" rungate)"
check "a FAIL sends the work back"                    'printf "%s" "$out" | grep -q "\"decision\": \"block\""'
check "progress reports the pipeline's limit (5), not the default" '[ "$(jq -r .max "$IDIR/review-progress.json")" = 5 ]'
check "the chat sees a returned round 1 of 5"         '[ "$(ev gate.review retrying | jq -r ".round,.max" | tr "\n" " ")" = "1 5 " ]'
mkcase '{"review":true,"maxRounds":40}'; work
out="$(FAKE_VERDICT=FAIL FAKE_FINDING="[acceptance_failure] x" rungate)"
check "a limit above the engine's ceiling is clamped to it" '[ "$(jq -r .max "$IDIR/review-progress.json")" = "$SUPERVISOR_MAX_ROUNDS_HARD" ]'

echo "== a required skill is checked in the transcript =="
mkcase '{"review":true,"maxRounds":3,"requiredSkills":["minimalist-ui"]}'; work
out="$(rungate s-skill-1)"
check "no Skill call → the work goes back"            'printf "%s" "$out" | grep -q "decision"'
check "and the reason names the skill"                'printf "%s" "$out" | grep -q "minimalist-ui"'
check "the reviewer was not even asked"               '[ ! -f "$CODEX_CALLED" ]'
check "the chat sees the skill gate fail, attempt 1"  '[ "$(ev gate.skill failed | jq -r .attempt)" = 1 ]'
out="$(rungate s-skill-1)"
check "a second miss parks for the director"          'done_is needs-user'
check "with the reason in the blocked note"           'grep -q "minimalist-ui" "$(run_reports_dir "$(slug_for "$PROJ")")/blocked.md" 2>/dev/null'
mkcase '{"review":true,"maxRounds":3,"requiredSkills":["minimalist-ui"]}'; work; skill_called minimalist-ui
out="$(rungate s-skill-2)"
check "with the call in the transcript the work goes on to review and passes" 'done_is passed && [ -f "$CODEX_CALLED" ]'
check "the chat sees the skill verified"              '[ -n "$(ev gate.skill verified)" ]'
mkcase '{"review":true,"maxRounds":3,"requiredSkills":["minimalist-ui"]}'; work
old_ts="2000-01-01T00:00:00.000Z"
printf '%s\n' "{\"type\":\"assistant\",\"timestamp\":\"$old_ts\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"t0\",\"name\":\"Skill\",\"input\":{\"skill\":\"minimalist-ui\"}}]}}" >> "$TR"
printf '%s\n' "{\"type\":\"user\",\"timestamp\":\"$old_ts\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"t0\",\"content\":\"ok\"}]}}" >> "$TR"
out="$(rungate s-skill-3)"
check "a call from BEFORE this task does not count"   'printf "%s" "$out" | grep -q "decision"'
mkcase '{"review":true,"maxRounds":3,"requiredSkills":["minimalist-ui"]}'
out="$(rungate s-skill-4)"
check "a stop with no work at all is the outcome protocol's business, not the skill's" '! printf "%s" "$out" | grep -q "minimalist-ui"'

echo "== a research pipeline's report is reviewed as a report =="
GATES_R='{"review":false,"reportReview":true,"reportMaxRounds":2,"research":true,"requiredSkills":[]}'
mkcase "$GATES_R"
mkdir -p "$PROJ/artifacts/r1"; printf '<html><body><h1>Звіт</h1><p>Ринок <a href="https://example.org/x">джерело</a>.</p><script>alert(1)</script></body></html>' > "$PROJ/artifacts/r1/index.html"
outcome succeeded_research "Готово: artifacts/r1/index.html"
out="$(rungate s-res-1)"
check "the report reviewer read the REPORT"           'grep -q "Звіт" "$CODEX_CALLED.report-prompt" && grep -q "example.org" "$CODEX_CALLED.report-prompt"'
check "as text — scripts are dropped, never handed over" '! grep -q "alert(1)" "$CODEX_CALLED.report-prompt"'
check "PASS accepts the run — it is no longer debt"   'done_is passed'
check "the chat sees the report review verified"      '[ -n "$(ev gate.reportReview verified)" ]'
mkcase "$GATES_R"
mkdir -p "$PROJ/artifacts"; printf '# Звіт\nРинок зріс на 40%%.\n' > "$PROJ/artifacts/report.md"
outcome succeeded_research "Готово"
out="$(FAKE_REPORT_VERDICT=FAIL rungate s-res-2)"
check "an unnamed report is found as the newest in artifacts/, and a FAIL sends it back" 'printf "%s" "$out" | grep -q "40%"'
check "the chat sees round 1 of 2 returned"           '[ "$(ev gate.reportReview retrying | jq -r ".round,.max" | tr "\n" " ")" = "1 2 " ]'
out="$(FAKE_REPORT_VERDICT=FAIL rungate s-res-2)"
check "at the pipeline's limit it parks for the director" 'done_is needs-user'
mkcase "$GATES_R"
outcome succeeded_research "Готово"
out="$(rungate s-res-3)"
check "no report anywhere → the worker is asked to name it" 'printf "%s" "$out" | grep -q "artifacts/"'
check "and nobody reviewed thin air"                  '[ ! -f "$CODEX_CALLED.report-prompt" ]'
mkcase '{"review":true,"reportReview":false,"research":true}'
outcome succeeded_research "Готово"
out="$(rungate s-res-4)"
check "without a report reviewer research stays what it always was: debt for a person" 'done_is debt'

echo "== review budgets: defaults, 0 = no limit, a task's own ceiling =="
mkcase '{"reportReview":true,"research":true}'
mkdir -p "$PROJ/artifacts"; printf '# Звіт\nРинок зріс на 40%%.\n' > "$PROJ/artifacts/report.md"
outcome succeeded_research "Готово: artifacts/report.md"
out="$(unset SUPERVISOR_REPORT_REVIEW_ROUNDS; FAKE_REPORT_VERDICT=FAIL rungate s-bud-1)"
check "a report with no number of its own gets the engine's default, 5 rounds (it was a fixed 2)" '[ "$(ev gate.reportReview retrying | jq -r ".round,.max" | tr "\n" " ")" = "1 5 " ]'
mkcase '{"reportReview":true,"research":true,"reportMaxRounds":0}'
mkdir -p "$PROJ/artifacts"; printf '# Звіт\nРинок зріс на 40%%.\n' > "$PROJ/artifacts/report.md"
outcome succeeded_research "Готово: artifacts/report.md"
for i in 1 2 3 4; do out="$(SUPERVISOR_MAX_ROUNDS_HARD=3 FAKE_REPORT_VERDICT=FAIL rungate s-bud-2)"; done
check "a report limit of 0 is no limit: the 4th FAIL still goes back, past the code ceiling of 3" 'printf "%s" "$out" | grep -q "\"decision\": \"block\"" && [ ! -s "$IDIR/done" ]'
check "…the chat is told the round with no maximum"   '[ "$(jq -c "select(.stage==\"gate.reportReview\" and .state==\"retrying\") | .max" "$IDIR/run-events.jsonl" | tail -1)" = null ]'
check "…and the reviewer is not told of a limit"      '! grep -q "of at most" "$CODEX_CALLED.report-prompt"'

mkcase '{"reportReview":true,"research":true,"reportMaxRounds":1,"reportAtLimit":"accept"}'
mkdir -p "$PROJ/artifacts"; printf '# Звіт\nРинок зріс на 40%%.\n' > "$PROJ/artifacts/report.md"
outcome succeeded_research "Готово: artifacts/report.md"
mkdir -p "$IDIR/report"; printf '{"result":"succeeded_research"}' > "$IDIR/report/receipt.json"
out="$(FAKE_REPORT_VERDICT=FAIL rungate s-bud-3)"
RJ="$(run_reports_dir "$(slug_for "$PROJ")")/review.json"
check "…and the receipt the bridge reads carries the flag and the notes" 'jq -e ".review == \"passed\" and .accepted_with_notes == true and (.review_why | test(\"40%\"))" "$IDIR/report/receipt.json" >/dev/null' 
check "a task that asked for it: a report failing at its limit is accepted" 'done_is passed'
check "…the record keeps the FAIL and the notes, and says it was let through" 'jq -e ".verdict == \"FAIL\" and .disposition == \"passed\" and .accepted_with_notes == true and (.findings | test(\"40%\"))" "$RJ" >/dev/null'
check "…and the run view says so in words"            'ev run passed | jq -r .note | grep -q "із зауваженнями"'
mkcase '{"reportReview":true,"research":true,"reportMaxRounds":1,"reportAtLimit":"accept"}'
mkdir -p "$PROJ/artifacts"; printf '# Звіт\nРинок зріс на 40%%.\n' > "$PROJ/artifacts/report.md"
outcome succeeded_research "Готово: artifacts/report.md"
out="$(FAKE_REPORT_GARBLED=1 rungate s-bud-3b)"
RJ="$(run_reports_dir "$(slug_for "$PROJ")")/review.json"
check "an answer with no readable verdict is never accepted with notes" 'done_is needs-user && ! jq -e .accepted_with_notes "$RJ" >/dev/null 2>&1'
check "…and is not recorded as a FAIL the reviewer never gave" '[ "$(jq -r .verdict "$RJ")" = N/A ] && [ "$(jq -r .state "$RJ")" = UNREADABLE ]'
mkcase '{"reportReview":true,"research":true,"reportMaxRounds":1}'
mkdir -p "$PROJ/artifacts"; printf '# Звіт\nРинок зріс на 40%%.\n' > "$PROJ/artifacts/report.md"
outcome succeeded_research "Готово: artifacts/report.md"
out="$(FAKE_REPORT_VERDICT=FAIL rungate s-bud-4)"
RJ="$(run_reports_dir "$(slug_for "$PROJ")")/review.json"
check "without that, the same report waits for a person, as before" 'done_is needs-user && ! jq -e .accepted_with_notes "$RJ" >/dev/null 2>&1'

mkcase '{"review":true,"maxRounds":0}'
for i in 1 2 3; do work; out="$(SUPERVISOR_MAX_ROUNDS_HARD=2 FAKE_VERDICT=FAIL FAKE_FINDING="[acceptance_failure] пункт $i" rungate s-bud-5)"; done
check "a pipeline loop of 0 lifts the ceiling: round 3 goes back past a ceiling of 2" 'printf "%s" "$out" | grep -q "\"decision\": \"block\"" && [ ! -s "$IDIR/done" ]'
check "…and the worker is told there is no ceiling"   'printf "%s" "$out" | grep -q "стелі раундів немає"'
mkcase '{"review":true,"maxRounds":0}'
for i in 1 2 3 4 5 6; do work; out="$(SUPERVISOR_MAX_ROUNDS=2 SUPERVISOR_MAX_ROUNDS_HARD=0 FAKE_VERDICT=FAIL FAKE_FINDING="[repeat] [acceptance_failure] те саме" rungate s-bud-6)"; [ -s "$IDIR/done" ] && break; done
check "with no ceiling, the same finding coming back still parks the run for a person" 'done_is needs-user'

mkcase '{"roundsCeiling":2}'
work; out="$(FAKE_VERDICT=FAIL FAKE_FINDING="[acceptance_failure] перше" rungate s-bud-7)"
check "a task's own ceiling of 2: round 1 goes back"  'printf "%s" "$out" | grep -q "\"decision\": \"block\""'
work; out="$(FAKE_VERDICT=FAIL FAKE_FINDING="[acceptance_failure] друге" rungate s-bud-7)"
check "…round 2 is the last one"                      'done_is debt'
mkcase '{"roundsCeiling":30}'
work; out="$(SUPERVISOR_MAX_ROUNDS_HARD=12 FAKE_VERDICT=FAIL FAKE_FINDING="[acceptance_failure] x" rungate s-bud-8)"
check "a task's ceiling is its own, above the engine's" 'printf "%s" "$out" | grep -q "ще 29 можливих"'

mkcase '{"review":true,"maxRounds":0,"roundsCeiling":2}'
work; out="$(FAKE_VERDICT=FAIL FAKE_FINDING="[acceptance_failure] перше" rungate s-bud-9)"
work; out="$(FAKE_VERDICT=FAIL FAKE_FINDING="[acceptance_failure] друге" rungate s-bud-9)"
check "a task's --max-rounds wins over its pipeline's loop of 0: round 2 is the last" 'done_is debt'
mkcase '{"review":true,"maxRounds":5,"roundsCeiling":0}'
for i in 1 2 3; do work; out="$(SUPERVISOR_MAX_ROUNDS_HARD=2 FAKE_VERDICT=FAIL FAKE_FINDING="[acceptance_failure] пункт $i" rungate s-bud-10)"; done
check "…and its 0 wins over the pipeline's number"   'printf "%s" "$out" | grep -q "стелі раундів немає" && [ ! -s "$IDIR/done" ]'

mkcase '{"roundsCeiling":3,"reportReview":true,"reportMaxRounds":5,"reportAtLimit":"accept"}'
mkdir -p "$PROJ/artifacts"; printf '# Звіт\nРинок зріс на 40%%.\n' > "$PROJ/artifacts/report.md"
outcome succeeded_research "Готово: artifacts/report.md"
for i in 1 2 3 4; do out="$(SUPERVISOR_MAX_ROUNDS_HARD=20 FAKE_REPORT_VERDICT=FAIL rungate s-rep-5)"; done
check "--max-rounds 3 --report-max-rounds 5: the report's 4th FAIL still goes back, not accepted early" 'printf "%s" "$out" | grep -q "коло 4 з 5" && [ ! -s "$IDIR/done" ]'
out="$(FAKE_REPORT_VERDICT=FAIL rungate s-rep-5)"
check "…its 5th is the limit, and only then accepted with notes" 'done_is passed && jq -e .accepted_with_notes "$(run_reports_dir "$(slug_for "$PROJ")")/review.json" >/dev/null'
mkcase '{"roundsCeiling":3,"reportReview":true,"reportMaxRounds":5}'
mkdir -p "$PROJ/artifacts"; printf '# Звіт\nРинок зріс на 40%%.\n' > "$PROJ/artifacts/report.md"
outcome succeeded_research "Готово: artifacts/report.md"
for i in 1 2 3 4; do out="$(FAKE_REPORT_VERDICT=FAIL rungate s-rep-5b)"; done
out="$(FAKE_REPORT_VERDICT=PASS rungate s-rep-5b)"
check "…and a PASS on that 5th round passes"          'done_is passed && ! jq -e .accepted_with_notes "$(run_reports_dir "$(slug_for "$PROJ")")/review.json" >/dev/null 2>&1'
mkcase '{"reportReview":true,"reportMaxRounds":30}'
mkdir -p "$PROJ/artifacts"; printf '# Звіт\nРинок зріс на 40%%.\n' > "$PROJ/artifacts/report.md"
outcome succeeded_research "Готово: artifacts/report.md"
for i in $(seq 1 29); do out="$(SUPERVISOR_MAX_ROUNDS_HARD=20 FAKE_REPORT_VERDICT=FAIL rungate s-rep-30)"; done
check "--report-max-rounds 30 with the code ceiling at 20: the 29th FAIL still goes back" 'printf "%s" "$out" | grep -q "коло 29 з 30" && [ ! -s "$IDIR/done" ]'
out="$(SUPERVISOR_MAX_ROUNDS_HARD=20 FAKE_REPORT_VERDICT=PASS rungate s-rep-30)"
check "…and a PASS on the 30th passes"               'done_is passed'

echo "== a task's report criteria replace the server's rule =="
printf 'Тестові дані на тестовому стенді допустимі, достатньо їх перелічити.\n' > "$FAKE/criteria.md"
mkcase "$(jq -nc --arg c "$FAKE/criteria.md" '{reportReview:true, reportCriteria:$c}')"
mkdir -p "$PROJ/artifacts"; printf '# Звіт\nПрогін тестів.\n' > "$PROJ/artifacts/report.md"
outcome succeeded_research "Готово: artifacts/report.md"
out="$(SUPERVISOR_PROFILE=server rungate s-crit-1)"
check "on a server the task's criteria are what the report is judged by" 'grep -q "тестовому стенді" "$CODEX_CALLED.report-prompt"'
check "…instead of the rule about changing data"      '! grep -q "If the task changed data" "$CODEX_CALLED.report-prompt"'
mkcase '{"reportReview":true,"reportMaxRounds":3}'
outcome succeeded_research "Видалив 3 тестові записи командою X і перевірив, що їх нема."
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Видалено 3 записи"}]}}' > "$TR"
out="$(SUPERVISOR_PROFILE=server rungate s-crit-2)"
check "with no criteria of its own the server's rule stays" 'grep -q "If the task changed data" "$CODEX_CALLED.report-prompt"'
check "…and a summary with no report file is still read, as on any server research" 'grep -q "Видалив 3 тестові записи" "$CODEX_CALLED.report-prompt"'


echo
echo "pipeline gates: $pass passed, $fail failed"
[ "$fail" = 0 ]
