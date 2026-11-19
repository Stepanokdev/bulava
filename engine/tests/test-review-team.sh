#!/bin/bash
# The final code review by a team of focused reviewers (bin/lib/review-team.sh).
#
# The bench (Nov 8–9) found three specialists — contract, security, state — catching 72.5% of
# planted defects where one ordinary reviewer caught 61.8%, with findings joined and no vote. Pinned:
#   • each member reads the same prompt with its own focus, worded as on the bench; they run side by
#     side; one finding from any member sends the work back, with every member's list under its name
#   • all members passing is a pass
#   • a member that did not answer is named and the others decide; none answering is the single
#     reviewer's "no answer"
#   • no team set, a team of one, or the Claude stand-in reading: one review call, as before
#   • on by default only under SUPERVISOR_PROFILE=server; the doctor says what is set
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SUPERVISOR_STATE_DIR="$(mktemp -d)"
. "$ROOT/bin/supervisor-lib.sh"
GATE="$ROOT/hooks/review-gate.sh"
export SUPERVISOR_CODEX_USAGE_CMD="/usr/bin/true"
export CODEX_SESSIONS_DIR="$(mktemp -d)"
unset SUPERVISOR_REVIEW_TEAM SUPERVISOR_PROFILE
# The engine's defaults, whatever the session running the test was given.
export ROOT SUPERVISOR_MAX_REMEDIATIONS=4 SUPERVISOR_MAX_ROUNDS=5 SUPERVISOR_MAX_ROUNDS_HARD=20 SUPERVISOR_STALL_LIMIT=2

pass=0; fail=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
no(){ echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

FAKE="$(mktemp -d)"; export CALLS="$FAKE/calls"
# A Codex that answers as the member whose focus it was given: FAKE_<ROLE>=PASS|FAIL|SILENT|SLOW.
cat > "$FAKE/codex" <<'EOF'
#!/bin/bash
if [ "${1:-}" = login ]; then echo "Logged in using ChatGPT"; exit 0; fi
p="${@: -1}"; [ "$p" = - ] && p="$(cat)"   # the engine sends prompts on stdin
case "$p" in
  "DUPLICATE CHECK."*) echo "dupcheck $(date +%s)" >> "$CALLS"; printf '%s\n' "${FAKE_MERGE:-NONE}"; exit 0 ;;
  *"Prioritize requirements and business correctness"*) role=contract ;;
  *"Prioritize security and data integrity"*)           role=security ;;
  *"Prioritize state transitions and integration"*)     role=state ;;
  *"You have no particular focus"*)                     role=general ;;
  *)                                                     role=single ;;
esac
printf '%s %s\n' "$role" "$(date +%s)" >> "$CALLS"
printf '%s' "$p" > "$CALLS.$role.prompt"
var="FAKE_$(printf '%s' "$role" | tr a-z A-Z)"; how="${!var:-PASS}"
case "$how" in
  SILENT)    exit 1 ;;
  SLOW)      sleep 2; how=PASS ;;
  BLOCKED)   echo "STATE: BLOCKED"; echo "VERDICT: N/A"; echo "$role needs access to the staging database"; exit 0 ;;
  HANDOFF)   echo "STATE: HANDOFF"; echo "VERDICT: N/A"; echo "$role: the worker stopped half way"; exit 0 ;;
  NOVERDICT) echo "STATE: COMPLETE"; echo "looked at it"; exit 0 ;;
  # The same defect back, plus an advisory: no progress, whatever the advisory adds to the count.
  # A fix check: answer the ledger's ids, as the prompt asks.
  FIXED_ALL|OPEN_ALL|FIX_FIRST|PASS_SILENT|SAME_TWICE|SAME_FIXED|NOVERDICT_FIX|SCOPE_ONLY|COMMIT_DURING|PASSQ|NEWREG|CONFLICT|FIXED_NOTE)
             ids="$(printf '%s\n' "$p" | grep -oE '^[TN][0-9]+:' | tr -d : | awk '!s[$0]++')"
             first="$(printf '%s\n' "$ids" | head -1)"
             case "$how" in
               FIXED_ALL)  echo "STATE: COMPLETE"; echo "VERDICT: PASS"; for i in $ids; do echo "$i: FIXED"; done ;;
               OPEN_ALL)   echo "STATE: COMPLETE"; echo "VERDICT: FAIL"; for i in $ids; do echo "$i: OPEN — still there"; done ;;
               FIX_FIRST)  echo "STATE: COMPLETE"; echo "VERDICT: FAIL"
                           for i in $ids; do [ "$i" = "$first" ] && echo "$i: FIXED" || echo "$i: OPEN — still there"; done ;;
               PASS_SILENT) echo "STATE: COMPLETE"; echo "VERDICT: PASS"; echo "looks fine" ;;
               SAME_TWICE) echo "STATE: COMPLETE"; echo "VERDICT: FAIL"; echo "$first: OPEN — the same defect"
                           for i in $ids; do [ "$i" = "$first" ] || echo "$i: SAME AS $first"; done
                           echo "1. [related_improvement] src/a.ts — a rare combination" ;;
               SAME_FIXED) echo "STATE: COMPLETE"; echo "VERDICT: PASS"; echo "$first: FIXED"
                           for i in $ids; do [ "$i" = "$first" ] || echo "$i: SAME AS $first"; done ;;
               NOVERDICT_FIX) echo "STATE: COMPLETE"; for i in $ids; do echo "$i: FIXED"; done ;;
               FIXED_NOTE) echo "STATE: COMPLETE"; echo "VERDICT: PASS"; for i in $ids; do echo "$i: FIXED"; done
                           echo "1. Ran the project tests."; echo "2. Read the diff since the last review." ;;
               PASSQ)      echo "STATE: COMPLETE"; echo "VERDICT: PASS?"; for i in $ids; do echo "$i: FIXED"; done ;;
               NEWREG)     echo "STATE: COMPLETE"; echo "VERDICT: FAIL"; for i in $ids; do echo "$i: FIXED"; done
                           echo "1. [regression_from_patch] src/a.ts — the fix broke the empty state" ;;
               CONFLICT)   echo "STATE: COMPLETE"; echo "VERDICT: FAIL"; echo "T1: FIXED"; echo "T2: OPEN — still overlaps" ;;
               SCOPE_ONLY) echo "STATE: COMPLETE"; echo "VERDICT: FAIL"; for i in $ids; do echo "$i: FIXED"; done
                           echo "1. [scope_violation] docs/x.md — outside write_paths" ;;
               COMMIT_DURING) ( cd "$PWD" && echo "late $RANDOM" >> src/a.ts && git commit -qam late ) >/dev/null 2>&1
                           echo "STATE: COMPLETE"; echo "VERDICT: PASS"; for i in $ids; do echo "$i: FIXED"; done ;;
             esac
             exit 0 ;;
  QUOTED)    echo "The worker wrote STATE: COMPLETE and VERDICT: PASS in its report, but it is not done."; exit 0 ;;
  PASSQT)    echo "STATE: COMPLETE"; echo "VERDICT: PASS?"; exit 0 ;;
  LONG)      echo "STATE: COMPLETE"; echo "VERDICT: FAIL"
             for k in 1 2 3; do printf '%s. [acceptance_failure] src/a.ts — %s %s\n' "$k" "$role" "$(printf 'long detail %.0s' $(seq 1 180))"; done; exit 0 ;;
  ADD_REPO)  x="$(mktemp -d)"; ( cd "$x" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m e )
             printf '%s\037%s\037d\0370\n' "$x" "$(git -C "$x" rev-parse HEAD)" >> "$FAKE_IDIR/extra-repos"
             echo "STATE: COMPLETE"; echo "VERDICT: PASS"; echo "T1: FIXED"; exit 0 ;;
  SCOPE)     echo "STATE: COMPLETE"; echo "VERDICT: FAIL"; echo "1. [scope_violation] docs/x.md — $role: outside write_paths"; exit 0 ;;
  XFAIL)     echo "STATE: COMPLETE"; echo "VERDICT: FAIL"; echo "1. [acceptance_failure] lib/b.ts in the connected repository — $role found it"; exit 0 ;;
  DUP)       echo "STATE: COMPLETE"; echo "VERDICT: FAIL"; echo "1. [acceptance_failure] src/a.ts — the label overlaps ($role's words)"; exit 0 ;;
  HARNESS)   echo "STATE: COMPLETE"; echo "VERDICT: FAIL"
             echo "1. [harness_failure] the verifier could not run the build"; exit 0 ;;
  REPEAT)    echo "STATE: COMPLETE"; echo "VERDICT: FAIL"
             echo "1. [acceptance_failure] [repeat] src/a.ts — $role: still there"
             echo "2. [related_improvement] src/a.ts — $role: a rare combination"; exit 0 ;;
esac
echo "STATE: COMPLETE"; echo "VERDICT: $how"
[ "$how" = FAIL ] && echo "1. [acceptance_failure] src/a.ts — $role found it"
sleep 1
exit 0
EOF
chmod +x "$FAKE/codex"
TR="$(mktemp)"; printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"text","text":"готово"}]}}' > "$TR"
REPOS=()
cleanup(){ rm -rf "$SUPERVISOR_STATE_DIR" "$FAKE" "$TR" "$CODEX_SESSIONS_DIR" ${REPOS[@]+"${REPOS[@]}"}; }
trap cleanup EXIT

mkcase(){
  RID="team-run-$RANDOM$RANDOM"
  PROJ="$(mktemp -d)"; REPOS+=("$PROJ")
  ( cd "$PROJ" && git init -q && git config user.email t@t && git config user.name t \
      && mkdir src && echo base > src/a.ts && git add -A && git commit -qm init >/dev/null )
  IDIR="$(instance_dir "$(slug_for "$PROJ")")"; mkdir -p "$IDIR"
  printf '%s\n' "$(canon_path "$PROJ")" > "$IDIR/project"
  printf '%s\n' "$RID" > "$IDIR/run-id"
  printf '%s\n' "$(git -C "$PROJ" rev-parse HEAD)" > "$IDIR/base-sha"
  echo "work $RANDOM" >> "$PROJ/src/a.ts"; git -C "$PROJ" commit -qam work
  jq -nc --arg r "$RID" '{result:"succeeded_changes", summary:"готово", run_id:$r, ts:"2026-11-11 12:00"}' > "$IDIR/outcome.json"
  rm -f "$CALLS" "$CALLS".*
}
rungate(){
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "s-$RANDOM" "$TR" "$PROJ" \
    | ORCHESTRATOR_RUN_ID="$RID" SUPERVISOR_VERIFIER_ENABLED=0 PATH="$FAKE:$PATH" "$GATE" 2>/dev/null
}
calls(){ grep -c . "$CALLS" 2>/dev/null || echo 0; }
done_is(){ [ "$(cat "$IDIR/done" 2>/dev/null)" = "$1" ]; }

echo "===== the members ====="
check "off by default on the Mac"                '[ -z "$(SUPERVISOR_REVIEW_TEAM= review_team_members)" ]'
check "the measured team"                        '[ "$(SUPERVISOR_REVIEW_TEAM="contract security state" review_team_members | tr "\n" " ")" = "contract security state " ]'
check "unknown names and repeats are dropped"    '[ "$(SUPERVISOR_REVIEW_TEAM="contract bogus contract state" review_team_members | tr "\n" " ")" = "contract state " ]'
check "a team of one is the single review"       '[ -z "$(SUPERVISOR_REVIEW_TEAM="security" review_team_members)" ]'
check "off is off"                               '[ -z "$(SUPERVISOR_REVIEW_TEAM=off review_team_members)" ]'
check "the server profile has the team by default" '[ "$(env -i HOME="$HOME" PATH="$PATH" SUPERVISOR_PROFILE=server bash -c ". \"$ROOT/supervisor/config.sh\" >/dev/null 2>&1; printf %s \"\$SUPERVISOR_REVIEW_TEAM\"")" = "contract security state" ]'
check "the Mac does not"                         '[ -z "$(env -i HOME="$HOME" PATH="$PATH" bash -c ". \"$ROOT/supervisor/config.sh\" >/dev/null 2>&1; printf %s \"\$SUPERVISOR_REVIEW_TEAM\"")" ]'
check "the focus is the bench's, word for word"  'review_team_focus contract | grep -q "derive expected behavior from the task, trace the implementation, and examine unmet acceptance criteria, boundary conditions and incorrect test assertions"'

echo "===== two specialists find different defects: both go back, under their names ====="
mkcase
out="$(SUPERVISOR_REVIEW_TEAM="contract security state" FAKE_CONTRACT=FAIL FAKE_STATE=FAIL rungate)"
check "three calls, one per member, and the duplicate check for two findings" '[ "$(calls)" = 4 ] && [ "$(grep -c ^dupcheck "$CALLS")" = 1 ]'
check "they ran side by side"                    '[ $(( $(grep -v ^dupcheck "$CALLS" | cut -d" " -f2 | sort -n | tail -1) - $(grep -v ^dupcheck "$CALLS" | cut -d" " -f2 | sort -n | head -1) )) -le 1 ]'
check "each with its own focus"                  'grep -q "YOUR FOCUS: Prioritize security" "$CALLS.security.prompt" && ! grep -q "Prioritize security" "$CALLS.contract.prompt"'
check "and the same shared prompt"               'grep -q "OUTPUT FORMAT" "$CALLS.contract.prompt" && grep -q "OUTPUT FORMAT" "$CALLS.state.prompt"'
check "the work goes back"                       'printf "%s" "$out" | grep -q "\"decision\""'
reason="$(printf '%s' "$out" | jq -r .reason 2>/dev/null)"
check "with the contract reviewer's finding"     'printf "%s" "$reason" | grep -q "contract found it"'
check "and the state reviewer's"                 'printf "%s" "$reason" | grep -q "state found it"'
check "each under its reviewer's name"           'printf "%s" "$reason" | grep -q "Contract and business logic: FAIL" && printf "%s" "$reason" | grep -q "State transitions and integrations: FAIL"'
check "the record of who answered is kept"       'jq -e ".answered == 3 and .verdict == \"FAIL\"" "$IDIR/review-team.json" >/dev/null'

echo "===== all three pass: a pass ====="
mkcase
SUPERVISOR_REVIEW_TEAM="contract security state" rungate >/dev/null
check "three calls"                              '[ "$(calls)" = 3 ]'
check "passed"                                   'done_is passed'

echo "===== one member does not answer: named, and the others decide ====="
mkcase
out="$(SUPERVISOR_REVIEW_TEAM="contract security state" FAKE_SECURITY=SILENT FAKE_CONTRACT=FAIL rungate)"
reason="$(printf '%s' "$out" | jq -r .reason 2>/dev/null)"
check "the others' finding still goes back"      'printf "%s" "$reason" | grep -q "contract found it"'
check "the silent one is named"                  'printf "%s" "$reason" | grep -q "did not answer: Security and data integrity"'
mkcase
SUPERVISOR_REVIEW_TEAM="contract security state" FAKE_SECURITY=SILENT rungate >/dev/null
check "with the others passing, it passes"       'done_is passed'
grep -q "did not answer: security" "$SUPERVISOR_STATE_DIR/supervisor.log" && ok "and the log says who did not" || no "no log line"

echo "===== a FAIL is not overruled by another member blocked or handing off ====="
mkcase
out="$(SUPERVISOR_REVIEW_TEAM="contract security state" FAKE_CONTRACT=FAIL FAKE_SECURITY=BLOCKED rungate)"
reason="$(printf '%s' "$out" | jq -r .reason 2>/dev/null)"
check "FAIL + BLOCKED + PASS: the work goes back"  'printf "%s" "$out" | grep -q "\"decision\"" && printf "%s" "$reason" | grep -q "contract found it"'
check "with the blocked member's line too"        'printf "%s" "$reason" | grep -q "Security and data integrity: BLOCKED" && printf "%s" "$reason" | grep -q "needs access to the staging database"'
check "not parked for a person"                   '! done_is needs-user'
mkcase
out="$(SUPERVISOR_REVIEW_TEAM="contract security state" FAKE_CONTRACT=FAIL FAKE_STATE=HANDOFF rungate)"
reason="$(printf '%s' "$out" | jq -r .reason 2>/dev/null)"
check "FAIL + HANDOFF + PASS: the work goes back with the finding" 'printf "%s" "$reason" | grep -q "contract found it" && printf "%s" "$reason" | grep -q "State transitions and integrations: HANDOFF"'
check "the joined review is a FAIL"               'jq -e ".state == \"COMPLETE\" and .verdict == \"FAIL\"" "$IDIR/review-team.json" >/dev/null'
mkcase
SUPERVISOR_REVIEW_TEAM="contract security state" FAKE_SECURITY=BLOCKED rungate >/dev/null
check "BLOCKED with no FAIL: the run waits for a person" 'jq -e ".state == \"BLOCKED\"" "$IDIR/review-team.json" >/dev/null && ! done_is passed'

echo "===== a COMPLETE with no verdict is not an answer ====="
mkcase
out="$(SUPERVISOR_REVIEW_TEAM="contract security state" FAKE_SECURITY=NOVERDICT rungate)"
check "the two who decided pass it"               'done_is passed'
check "and the one with no verdict is counted as not answering" 'jq -e ".answered == 2 and .of == 3" "$IDIR/review-team.json" >/dev/null'
grep -q "did not answer: security" "$SUPERVISOR_STATE_DIR/supervisor.log" && ok "and named in the log" || no "not named"
mkcase
SUPERVISOR_REVIEW_TEAM="contract security state" FAKE_CONTRACT=NOVERDICT FAKE_SECURITY=NOVERDICT FAKE_STATE=NOVERDICT rungate >/dev/null
check "nobody with a usable answer: not passed"   '! done_is passed'
grep -q "review team: no member answered" "$SUPERVISOR_STATE_DIR/supervisor.log" && ok "and the log says no member answered" || no "no log line"

echo "===== nobody answers: the single reviewer's 'no answer' ====="
mkcase
out="$(SUPERVISOR_REVIEW_TEAM="contract security state" FAKE_CONTRACT=SILENT FAKE_SECURITY=SILENT FAKE_STATE=SILENT rungate)"
check "not passed"                               '! done_is passed'
grep -q "review team: no member answered" "$SUPERVISOR_STATE_DIR/supervisor.log" && ok "the log says no member answered" || no "no log line"

echo "===== no team: one reviewer, as before ====="
mkcase
SUPERVISOR_REVIEW_TEAM= rungate >/dev/null
check "one call, with no team text"              '[ "$(calls)" = 1 ] && [ "$(cut -d" " -f1 "$CALLS")" = single ] && ! grep -q "REVIEW TEAM" "$CALLS.single.prompt"'
check "passed"                                   'done_is passed'
mkcase
SUPERVISOR_REVIEW_TEAM="general security" FAKE_GENERAL=FAIL rungate >/dev/null
check "a general member reads with no focus"     'grep -q "You have no particular focus" "$CALLS.general.prompt"'

echo "===== the pipeline the message went through chooses ====="
# The gates as the run records them (pipeline.sh: dispatch.json .pipeline_gates), compiled from the real
# built-in description, so the test breaks if the manifest stops naming the team.
PIPE_TMP="$(mktemp -d)"; REPOS+=("$PIPE_TMP")
python3 "$ROOT/bin/pipeline-tool.py" compile "$ROOT/supervisor/pipelines/manifests/review-team" --out "$PIPE_TMP/c.json" >/dev/null
gates_of(){ jq -c '.gates' "$PIPE_TMP/c.json"; }
with_gates(){ jq -nc --argjson g "$1" '{id:"d-1", task:"t", pipeline:"review-team", pipeline_gates:$g}' > "$IDIR/dispatch.json"; }
check "the built-in names the three specialists" '[ "$(jq -r ".gates.reviewTeam" "$PIPE_TMP/c.json")" = "contract security state" ]'
mkcase; with_gates "$(gates_of)"
SUPERVISOR_REVIEW_TEAM= rungate >/dev/null
check "Mac, no team set: the pipeline's team reads it" '[ "$(cut -d" " -f1 "$CALLS" | sort | tr "\n" " ")" = "contract security state " ]'
check "passed by the team"                       'done_is passed'
mkcase; with_gates "$(gates_of)"
SUPERVISOR_REVIEW_TEAM= FAKE_SECURITY=FAIL rungate >/dev/null
check "its finding sends the work back"          '! done_is passed && [ "$(calls)" = 3 ]'
mkcase; with_gates '{"review":true,"maxRounds":3,"reviewTeam":"off"}'
SUPERVISOR_REVIEW_TEAM="contract security state" rungate >/dev/null
check "a pipeline that chose one reviewer gets one, server default or not" '[ "$(calls)" = 1 ] && [ "$(cut -d" " -f1 "$CALLS")" = single ]'
mkcase; with_gates '{"review":true,"maxRounds":3}'
SUPERVISOR_REVIEW_TEAM="contract security state" rungate >/dev/null
check "a pipeline that did not choose leaves it to the engine" '[ "$(calls)" = 3 ]'
mkcase; with_gates '{"review":true,"maxRounds":3}'
SUPERVISOR_REVIEW_TEAM= rungate >/dev/null
check "…which on the Mac is one reviewer"        '[ "$(calls)" = 1 ]'

echo "===== the team reads once; the rounds after check its list with one reviewer ====="
# A server, 19 Nov: the team on every round found something new each time (7 → 11 → 4 → 6) and the
# run never stalled. Now: three calls on the first round, one on each after it, against a ledger.
team(){ SUPERVISOR_REVIEW_TEAM="contract security state" rungate; }
fix(){ echo "fix $RANDOM" >> "$PROJ/src/a.ts"; git -C "$PROJ" commit -qam fix; }
ledger_open(){ python3 "$ROOT/bin/lib/review-ledger.py" open "$SUPERVISOR_STATE_DIR/review-ledger-$RID" | grep -c .; }
mkcase
out="$(FAKE_CONTRACT=FAIL FAKE_STATE=FAIL team)"
check "round 1: the team, three calls, and one duplicate check for its two findings" '[ "$(calls)" = 4 ] && [ "$(grep -c ^dupcheck "$CALLS")" = 1 ] && printf "%s" "$out" | grep -q "\"decision\""'
check "its two defects are on the ledger as T1, T2" '[ "$(ledger_open)" = 2 ] && python3 "$ROOT/bin/lib/review-ledger.py" open "$SUPERVISOR_STATE_DIR/review-ledger-$RID" | grep -q "^T2: \[acceptance_failure\] src/a.ts — state found it"'
fix; rm -f "$CALLS" "$CALLS".*
out="$(FAKE_SINGLE=FIX_FIRST team)"
check "round 2: one call, no focus"              '[ "$(calls)" = 1 ] && [ "$(cut -d" " -f1 "$CALLS")" = single ] && ! grep -q "REVIEW TEAM" "$CALLS.single.prompt"'
check "it is told this is a fix check"           'grep -q "FIX CHECK — this is not a first reading" "$CALLS.single.prompt"'
check "with every open id, in full"              'grep -q "^T1: .*contract found it" "$CALLS.single.prompt" && grep -q "^T2: .*state found it" "$CALLS.single.prompt"'
check "and the fixes since the team read it"     'grep -q "WHAT CHANGED SINCE THE LAST REVIEW" "$CALLS.single.prompt" && grep -q "diff [0-9a-f]\{40\} [0-9a-f]\{40\}\`" "$CALLS.single.prompt"'
check "new rare cases do not block in it"        'grep -q "\[related_improvement\]: name it, and do not hold the work back" "$CALLS.single.prompt"'
check "T1 closed, T2 goes back to the worker"    '[ "$(ledger_open)" = 1 ] && printf "%s" "$out" | jq -r .reason | grep -q "^T2: .*state found it"'
grep -q "fix check after the team's review" "$SUPERVISOR_STATE_DIR/supervisor.log" && ok "the log says why one reviewer read it" || no "no log line"
fix; rm -f "$CALLS" "$CALLS".*
FAKE_SINGLE=FIXED_ALL team >/dev/null
check "round 3: one call again; all fixed, it passes" '[ "$(calls)" = 1 ] && done_is passed'
check "the pass clears the ledger"               '[ ! -e "$SUPERVISOR_STATE_DIR/review-ledger-$RID" ]'
check "the receipt-facing record says passed"    'jq -e ".disposition == \"passed\" or .verdict == \"PASS\"" "$IDIR/reports/review.json" >/dev/null 2>&1 || [ -f "$IDIR/done" ]'

echo "===== one defect, two descriptions: it does not fake progress ====="
mkcase
FAKE_CONTRACT=DUP FAKE_STATE=DUP team >/dev/null
check "two ids at first"                         '[ "$(ledger_open)" = 2 ]'
fix; rm -f "$CALLS" "$CALLS".*
FAKE_SINGLE=SAME_TWICE team >/dev/null
check "the fix check is told how to merge them"  'grep -q "SAME AS T1" "$CALLS.single.prompt"'
check "merged: one open, no progress 1"          '[ "$(ledger_open)" = 1 ] && [ "$(jq .stall "$SUPERVISOR_STATE_DIR/review-ledger-$RID")" = 1 ] && ! done_is needs-user'
fix; FAKE_SINGLE=SAME_TWICE team >/dev/null
check "round 3: stalled — a person, without waiting for round 5" 'done_is needs-user'
check "with the open item in the review record"  'jq -r .findings "$IDIR/reports/review.json" 2>/dev/null | grep -q "^T1: "'
mkcase
FAKE_CONTRACT=DUP FAKE_STATE=DUP team >/dev/null; fix
FAKE_SINGLE=SAME_FIXED team >/dev/null
check "merged and fixed: the one defect closes once, and it passes" 'done_is passed'
mkcase
FAKE_MERGE="T2: SAME AS T1" FAKE_CONTRACT=DUP FAKE_STATE=DUP team >/dev/null
check "the duplicate check right after the team merges them: one open" '[ "$(ledger_open)" = 1 ] && grep -q "duplicate check: T2=T1" "$SUPERVISOR_STATE_DIR/supervisor.log"'
fix; FAKE_SINGLE=CONFLICT team >/dev/null
check "T1 FIXED but its duplicate OPEN: still open, no progress" '[ "$(ledger_open)" = 1 ] && [ "$(jq .stall "$SUPERVISOR_STATE_DIR/review-ledger-$RID")" = 1 ]'
fix; FAKE_SINGLE=CONFLICT team >/dev/null
check "twice: a person"                          'done_is needs-user'
python3 - "$SUPERVISOR_STATE_DIR/l.json" <<'PY' && ok "statuses that disagree for one id read as OPEN, and FIXED? is not FIXED" || no "status parsing"
import json, subprocess, sys
p = sys.argv[1]
json.dump({"items": [{"id": "T1", "text": "a", "open": True}, {"id": "T2", "text": "b", "open": True}], "stall": 0, "rounds": 0}, open(p, "w"))
open(p + ".ans", "w").write("STATE: COMPLETE\nVERDICT: FAIL\nT1: FIXED\nT1: OPEN — no\nT2: FIXED?\n")
import os
r = json.loads(subprocess.check_output(["python3", os.environ["ROOT"] + "/bin/lib/review-ledger.py", "apply", p, p + ".ans", "[]"]))
assert r["closed"] == [] and r["open"] == ["T1", "T2"] and r["stall"] == 1, r
PY

echo "===== an id the answer leaves out stays open; an answer with no verdict changes nothing ====="
mkcase
FAKE_CONTRACT=FAIL team >/dev/null
fix; rm -f "$CALLS" "$CALLS".*
out="$(FAKE_SINGLE=PASS_SILENT team)"
check "a bare PASS: one call, refused, T1 sent back" '[ "$(calls)" = 1 ] && ! done_is passed && printf "%s" "$out" | jq -r .reason | grep -q "^T1: "'
check "T1 still open"                            '[ "$(ledger_open)" = 1 ]'
FAKE_SINGLE=NOVERDICT_FIX team >/dev/null
check "FIXED lines with no VERDICT close nothing" '[ "$(ledger_open)" = 1 ] && ! done_is passed'
FAKE_SINGLE=PASSQ team >/dev/null
check "\"VERDICT: PASS?\" is no verdict: FIXED lines close nothing" '[ "$(ledger_open)" = 1 ] && ! done_is passed'
echo "{broken" > "$SUPERVISOR_STATE_DIR/review-ledger-$RID"
FAKE_SINGLE=FIXED_ALL team >/dev/null
check "a damaged ledger is never passed on"      'done_is needs-user'

echo "===== open items are never debt ====="
mkcase
SUPERVISOR_MAX_ROUNDS_HARD=1 FAKE_CONTRACT=FAIL team >/dev/null
check "a ceiling of one round with a defect open: a person, not debt" 'done_is needs-user && jq -r .findings "$IDIR/reports/review.json" | grep -q "contract found it"'

echo "===== write_paths violations stay the gate's to quarantine ====="
mkcase; printf '%s' '{"schema":1,"mode":"patch","write_paths":["src/**"]}' > "$IDIR/runspec.json"
FAKE_CONTRACT=SCOPE FAKE_STATE=SCOPE team >/dev/null
check "the team finds only scope violations: quarantined, not sent back" 'done_is needs-user && { [ ! -e "$SUPERVISOR_STATE_DIR/review-ledger-$RID" ] || [ "$(ledger_open)" = 0 ]; }'
mkcase; printf '%s' '{"schema":1,"mode":"patch","write_paths":["src/**"]}' > "$IDIR/runspec.json"
FAKE_CONTRACT=FAIL team >/dev/null; fix
out="$(FAKE_SINGLE=SCOPE_ONLY team)"
check "after the team: all fixed, a scope violation left — quarantined, not another fix round" 'done_is needs-user && ! printf "%s" "$out" | grep -q "\"decision\""'

echo "===== a connected repository: its fixes are shown since the last review ====="
mkcase
XR="$(mktemp -d)"; REPOS+=("$XR")
( cd "$XR" && git init -q && git config user.email t@t && git config user.name t && mkdir lib && echo x > lib/b.ts && git add -A && git commit -qm base )
XR="$(canon_path "$XR")"
printf '%s\037%s\037%s\037%s\n' "$XR" "$(git -C "$XR" rev-parse HEAD)" d 0 > "$IDIR/extra-repos"
echo work >> "$XR/lib/b.ts"; git -C "$XR" commit -qam work
FAKE_CONTRACT=XFAIL team >/dev/null
xr_read="$(git -C "$XR" rev-parse HEAD)"
check "the ledger keeps the commit read in each repository" 'jq -e --arg p "$XR" --arg h "$xr_read" "any(.repos[]; .path == \$p and .reviewed_sha == \$h)" "$SUPERVISOR_STATE_DIR/review-ledger-$RID" >/dev/null'
echo "fix that breaks" >> "$XR/lib/b.ts"; git -C "$XR" commit -qam "a fix"
rm -f "$CALLS" "$CALLS".*
out="$(FAKE_SINGLE=OPEN_ALL team)"
check "the fix check gets that repository's diff since then" 'grep -q "in $XR: \`git -C .$XR. diff [0-9a-f]\{40\} [0-9a-f]\{40\}\`" "$CALLS.single.prompt" && grep -q "lib/b.ts" "$CALLS.single.prompt"'
check "and its defect stays open until confirmed fixed" '[ "$(ledger_open)" = 1 ] && printf "%s" "$out" | grep -q "\"decision\""'

echo "===== the team passes, the verifier fails: still one reviewer after ====="
mkcase
printf '#!/bin/sh\necho "suite red"; exit 1\n' > "$PROJ/verify.sh"; chmod +x "$PROJ/verify.sh"
git -C "$PROJ" add verify.sh; git -C "$PROJ" commit -qm verify
printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "s-$RANDOM" "$TR" "$PROJ" \
  | ORCHESTRATOR_RUN_ID="$RID" SUPERVISOR_REVIEW_TEAM="contract security state" PATH="$FAKE:$PATH" "$GATE" >/dev/null 2>&1
if grep -q "VERIFIER OVERRIDE" "$SUPERVISOR_STATE_DIR/supervisor.log" && [ "$(calls)" = 3 ]; then
  check "the ledger starts, empty"               '[ -f "$SUPERVISOR_STATE_DIR/review-ledger-$RID" ] && [ "$(ledger_open)" = 0 ]'
  rm -f "$CALLS" "$CALLS".*
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "s-$RANDOM" "$TR" "$PROJ" \
    | ORCHESTRATOR_RUN_ID="$RID" SUPERVISOR_REVIEW_TEAM="contract security state" PATH="$FAKE:$PATH" "$GATE" >/dev/null 2>&1
  check "the next round is one reviewer, told to check the failed machine checks" '[ "$(calls)" = 1 ] && grep -q "the machine checks in the evidence below failed" "$CALLS.single.prompt"'
else
  no "the verifier did not fail the team's pass here: $(grep -c . "$CALLS" 2>/dev/null) calls"
fi

echo "===== a new request, or a new task in the same run, is read by the team again ====="
mkcase
FAKE_CONTRACT=FAIL team >/dev/null
check "the team's FAIL starts a ledger"          '[ -s "$SUPERVISOR_STATE_DIR/review-ledger-$RID" ]'
reset_review_budget "$IDIR" "test: a new request"
rm -f "$CALLS" "$CALLS".*
FAKE_CONTRACT=FAIL team >/dev/null
check "after a new request, three calls"         '[ "$(calls)" = 3 ] && ! grep -q "FIX CHECK" "$CALLS.contract.prompt"'
( cd "$PROJ" && ORCHESTRATOR_RUN_ID="$RID" bash "$ROOT/bin/worker-task-boundary.sh" new "a different task" >/dev/null 2>&1 )
check "task-boundary new clears the old task's list and counts" '[ ! -e "$SUPERVISOR_STATE_DIR/review-ledger-$RID" ] && [ ! -e "$SUPERVISOR_STATE_DIR/rounds-findings-$RID" ] && [ ! -e "$SUPERVISOR_STATE_DIR/rounds-$RID" ]'
rm -f "$CALLS" "$CALLS".*
team >/dev/null
check "and the new task gets three calls"        '[ "$(calls)" = 3 ]'

echo "===== no team: nothing changes ====="
mkcase
SUPERVISOR_REVIEW_TEAM= FAKE_SINGLE=FAIL rungate >/dev/null
rm -f "$CALLS" "$CALLS".*
SUPERVISOR_REVIEW_TEAM= FAKE_SINGLE=FAIL rungate >/dev/null
check "a single reviewer is never told it is a fix check" '[ "$(calls)" = 1 ] && ! grep -q "FIX CHECK" "$CALLS.single.prompt" && [ ! -e "$SUPERVISOR_STATE_DIR/review-ledger-$RID" ]'

echo "===== a scoped task: 3 → 1 → 1, with fixes committed between ====="
mkcase; printf '%s' '{"schema":1,"mode":"patch","write_paths":["src/**"]}' > "$IDIR/runspec.json"
FAKE_SECURITY=FAIL FAKE_STATE=FAIL team >/dev/null
check "round 1: three calls and the duplicate check"   '[ "$(calls)" = 4 ] && [ "$(grep -c ^dupcheck "$CALLS")" = 1 ]'
fix; rm -f "$CALLS" "$CALLS".*
out="$(FAKE_SINGLE=FIX_FIRST team)"
check "round 2: one, and the open id goes back"  '[ "$(calls)" = 1 ] && grep -q "FIX CHECK" "$CALLS.single.prompt" && printf "%s" "$out" | grep -q "\"decision\""'
fix; rm -f "$CALLS" "$CALLS".*
FAKE_SINGLE=FIXED_ALL team >/dev/null
check "round 3: one, all fixed, accepted"        '[ "$(calls)" = 1 ] && done_is passed'
mkcase; printf '%s' '{"schema":1,"mode":"patch","write_paths":["src/**"]}' > "$IDIR/runspec.json"
FAKE_CONTRACT=FAIL team >/dev/null
fix; FAKE_SINGLE=OPEN_ALL team >/dev/null; fix; FAKE_SINGLE=OPEN_ALL team >/dev/null
check "scoped, nothing closes twice: a person"   'done_is needs-user'

echo "===== the verdict belongs to the commit the reviewer read ====="
mkcase
FAKE_CONTRACT=FAIL team >/dev/null
fix; out="$(FAKE_SINGLE=COMMIT_DURING team)"
check "a commit during the review: not accepted" '! done_is passed && printf "%s" "$out" | jq -r .reason | grep -q "новий коміт"'
check "and the ledger is untouched"              '[ "$(ledger_open)" = 1 ]'
mkcase
mkdir -p "$IDIR/report"; echo '{"schema":1}' > "$IDIR/report/receipt.json"
FAKE_CONTRACT=FAIL team >/dev/null; fix
read_sha="$(git -C "$PROJ" rev-parse HEAD)"
FAKE_SINGLE=FIXED_ALL team >/dev/null
check "the receipt names the commit that was read" 'done_is passed && [ "$(jq -r ".repos[0].reviewed_sha" "$IDIR/report/receipt.json")" = "$read_sha" ]'

echo "===== a fix not yet committed is shown, and a regression it brings holds the work ====="
mkcase
FAKE_CONTRACT=FAIL team >/dev/null
echo "uncommitted fix" >> "$PROJ/src/a.ts"
rm -f "$CALLS" "$CALLS".*
out="$(FAKE_SINGLE=NEWREG team)"
check "HEAD unchanged, the working tree's fix is in the diff" 'grep -q "uncommitted and new files included" "$CALLS.single.prompt" && grep -q "src/a.ts" "$CALLS.single.prompt"'
check "T1 closed, the fix's regression is N1 and holds FAIL" '[ "$(python3 "$ROOT/bin/lib/review-ledger.py" open "$SUPERVISOR_STATE_DIR/review-ledger-$RID")" = "N1: [regression_from_patch] src/a.ts — the fix broke the empty state" ] && printf "%s" "$out" | grep -q "\"decision\""'
fix; FAKE_SINGLE=FIXED_ALL team >/dev/null
check "N1 confirmed fixed: accepted"             'done_is passed'

echo "===== headers, notes and merges are read as they are written ====="
mkcase
SUPERVISOR_REVIEW_TEAM="contract security state" FAKE_CONTRACT=SILENT FAKE_SECURITY=SILENT FAKE_STATE=PASSQT rungate >/dev/null
check "two silent and one \"VERDICT: PASS?\": the team gives no PASS" '! done_is passed'
mkcase
SUPERVISOR_REVIEW_TEAM="contract security state" FAKE_CONTRACT=PASSQT FAKE_SECURITY=PASSQT FAKE_STATE=PASSQT rungate >/dev/null
check "three \"PASS?\": no PASS either"         '! done_is passed'
mkcase
FAKE_CONTRACT=FAIL team >/dev/null; fix
FAKE_SINGLE=FIXED_NOTE team >/dev/null
check "a PASS with numbered notes of what was checked stays a PASS" 'done_is passed'
python3 - <<'PY' && ok "\"SAME AS\" onto a closed item does not close an open one; \"FIXED or OPEN\" is no status" || no "ledger merge/status"
import json, os, subprocess, tempfile
L = os.environ["ROOT"] + "/bin/lib/review-ledger.py"
d = tempfile.mkdtemp(); p = d + "/l.json"
json.dump({"items": [{"id": "T1", "text": "a", "open": False}, {"id": "N1", "text": "b", "open": True}], "stall": 0, "rounds": 0}, open(p, "w"))
open(d + "/a", "w").write("STATE: COMPLETE\nVERDICT: FAIL\nN1: SAME AS T1\n")
r = json.loads(subprocess.check_output(["python3", L, "apply", p, d + "/a", "[]"]))
assert r["open"] == ["N1"], r
open(d + "/b", "w").write("STATE: COMPLETE\nVERDICT: PASS\nN1: FIXED or OPEN\n")
r = json.loads(subprocess.check_output(["python3", L, "apply", p, d + "/b", "[]"]))
assert r["open"] == ["N1"], r
PY

echo "===== a new file, not yet added, is in the fix check's diff ====="
mkcase
FAKE_CONTRACT=FAIL team >/dev/null
printf 'export const x = 1\n' > "$PROJ/src/brand-new.ts"
rm -f "$CALLS" "$CALLS".*
FAKE_SINGLE=NEWREG team >/dev/null
check "the diff between the two readings names the untracked file" 'grep -q "src/brand-new.ts" "$CALLS.single.prompt" && grep -q "what the last reviewer read → what you read now" "$CALLS.single.prompt"'
check "and a regression the reviewer finds in it is N1, holding the work" '[ "$(ledger_open)" = 1 ] && ! done_is passed'
git -C "$PROJ" status --porcelain | grep -q "?? src/brand-new.ts" && ok "the repository's own index is untouched (the file is still untracked)" || no "the snapshot staged files in the repository's index"

echo "===== a repository that joins during the review is not passed unread ====="
mkcase
FAKE_CONTRACT=FAIL team >/dev/null; fix
out="$(FAKE_IDIR="$IDIR" FAKE_SINGLE=ADD_REPO team)"
check "not passed; reviewed again"               '! done_is passed && printf "%s" "$out" | grep -q "\"decision\""'

echo "===== the whole open list reaches the receipt, however long ====="
mkcase
mkdir -p "$IDIR/report"; echo '{"schema":1}' > "$IDIR/report/receipt.json"
SUPERVISOR_MAX_ROUNDS_HARD=1 FAKE_CONTRACT=LONG team >/dev/null
check "parked for a person"                      'done_is needs-user'
check "the receipt carries every open item whole (over 4000 bytes)" '[ "$(jq ".open_items | length" "$IDIR/report/receipt.json")" = 3 ] && [ "$(jq -r "[.open_items[].text] | join(\"\") | length" "$IDIR/report/receipt.json")" -gt 4000 ]'
check "and review.json too"                      '[ "$(jq ".open_items | length" "$IDIR/reports/review.json")" = 3 ]'

echo "===== a record without a receipt names the commit read too ====="
mkcase
TID="TT-$RANDOM"; task_create "$TID" "$PROJ" test t "goal" main "$(git -C "$PROJ" rev-parse HEAD~1)" >/dev/null
printf '%s\n' "$TID" > "$IDIR/task-id"; jq -nc '{id:"d-1"}' > "$IDIR/dispatch.json"
task_attempt_begin "$TID" "$IDIR" d-1 initial >/dev/null
read_sha="$(git -C "$PROJ" rev-parse HEAD)"
echo late >> "$PROJ/src/a.ts"; git -C "$PROJ" commit -qam "after the verdict"
CP="$(canon_path "$PROJ")"   # the paths repos_state_json reports, as the gate's snapshot has them
REVIEW_SNAPSHOT="$(jq -nc --arg p "$CP" --arg h "$read_sha" '[{path:$p, reviewed_sha:$h}]')" task_on_terminal "$IDIR" passed
check "no receipt: .repos names the commit the reviewer read" '[ "$(task_get "$TID" ".repos[0].reviewed_sha")" = "$read_sha" ]'
check "and .repo_reviewed too, not the later commit" '[ "$(task_get "$TID" ".repo_reviewed[\"$CP\"]")" = "$read_sha" ]'

REVIEW_SNAPSHOT='[{"path":"/w/api","reviewed_sha":"aaa"}]'
got="$(repos_as_reviewed '[{"path":"/w/api","reviewed_sha":"bbb","clean":true},{"path":"/w/web","reviewed_sha":"ccc"}]')"
check "reviewed_sha is the commit read; a repository the reviewer never read has none" '[ "$(jq -r ".[0].reviewed_sha,.[1].reviewed_sha,.[1].unreviewed" <<<"$got" | tr "\\n" " ")" = "aaa  true " ]'
check "the task record (tasks.sh) and the receipt both go through it" 'grep -q "repos_as_reviewed \"\$repos\"" "$ROOT/bin/lib/tasks.sh" && grep -q "repos_as_reviewed \"\$repos\"" "$GATE"'
unset REVIEW_SNAPSHOT

echo "===== the header is the header ====="
mkcase
out="$(SUPERVISOR_REVIEW_TEAM= FAKE_SINGLE=QUOTED rungate)"
check "STATE/VERDICT inside a sentence is not a verdict" '! done_is passed'

echo "===== the doctor says what is set ====="
# With only the plain tools on PATH, so the doctor does not go asking claude and codex to sign in.
TOOLS="$(mktemp -d)"; for t in bash git jq python3 perl openssl curl tmux sh env uname sed awk grep cat; do p="$(command -v "$t")" && ln -s "$p" "$TOOLS/$t"; done
doctor_team(){ env -i HOME="$HOME" PATH="$TOOLS" SUPERVISOR_STATE_DIR="$SUPERVISOR_STATE_DIR" SUPERVISOR_PROFILE=server "$@" \
  python3 "$ROOT/bin/ns-cli.py" doctor --server --json 2>/dev/null | jq -c '.checks[] | select(.name == "engine.review_team") | .detail'; }
d="$(doctor_team)"
check "server: the team and its calls per round" 'printf "%s" "$d" | jq -e ".enabled == true and .calls_per_round == 3 and .calls_later_rounds == 1 and .members == [\"contract\",\"security\",\"state\"]" >/dev/null'
d="$(doctor_team SUPERVISOR_REVIEW_TEAM=off)"
check "server, turned off: one call a round"     'printf "%s" "$d" | jq -e ".enabled == false and .calls_per_round == 1" >/dev/null'
rm -rf "$TOOLS"

echo
echo "review team: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
