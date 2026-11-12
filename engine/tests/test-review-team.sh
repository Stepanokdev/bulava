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

pass=0; fail=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
no(){ echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

FAKE="$(mktemp -d)"; export CALLS="$FAKE/calls"
# A Codex that answers as the member whose focus it was given: FAKE_<ROLE>=PASS|FAIL|SILENT|SLOW.
cat > "$FAKE/codex" <<'EOF'
#!/bin/bash
if [ "${1:-}" = login ]; then echo "Logged in using ChatGPT"; exit 0; fi
p="${@: -1}"
case "$p" in
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
check "three calls, one per member"              '[ "$(calls)" = 3 ]'
check "they ran side by side"                    '[ $(( $(cut -d" " -f2 "$CALLS" | sort -n | tail -1) - $(cut -d" " -f2 "$CALLS" | sort -n | head -1) )) -le 1 ]'
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

echo "===== the doctor says what is set ====="
# With only the plain tools on PATH, so the doctor does not go asking claude and codex to sign in.
TOOLS="$(mktemp -d)"; for t in bash git jq python3 perl openssl curl tmux sh env uname sed awk grep cat; do p="$(command -v "$t")" && ln -s "$p" "$TOOLS/$t"; done
doctor_team(){ env -i HOME="$HOME" PATH="$TOOLS" SUPERVISOR_STATE_DIR="$SUPERVISOR_STATE_DIR" SUPERVISOR_PROFILE=server "$@" \
  python3 "$ROOT/bin/ns-cli.py" doctor --server --json 2>/dev/null | jq -c '.checks[] | select(.name == "engine.review_team") | .detail'; }
d="$(doctor_team)"
check "server: the team and its calls per round" 'printf "%s" "$d" | jq -e ".enabled == true and .calls_per_round == 3 and .members == [\"contract\",\"security\",\"state\"]" >/dev/null'
d="$(doctor_team SUPERVISOR_REVIEW_TEAM=off)"
check "server, turned off: one call a round"     'printf "%s" "$d" | jq -e ".enabled == false and .calls_per_round == 1" >/dev/null'
rm -rf "$TOOLS"

echo
echo "review team: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
