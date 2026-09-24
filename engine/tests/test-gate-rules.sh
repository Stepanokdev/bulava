#!/bin/bash
# Four rules the review gate learned from one week's log.
#
#   1. The same wrong declaration again is not progress. A worker declared `succeeded_research`
#      six times in one night with a non-empty diff; each time the gate ran the verifier and a
#      Codex round. Now the second identical declaration is blocked without a round, with the
#      right outcome spelled out, and the third parks the run for a person.
#   2. Handoffs are counted apart from failed rounds. Sharing the FAIL counter made the first
#      handoff after two FAILs a "repeated handoff" escalation.
#   3. A blocker finding is fresh for the dispatch it was filed under, not for the whole run.
#   4. Nothing changed since the last verdict ⇒ no second review. A stale notification woke an
#      accepted worker; its one-sentence stop bought a full verifier + Codex round, twice.
#   5. A verifier that had nothing to build or test does not turn the reviewer's PASS into debt.
#   6. Through the gate itself, with the real verifier: a test red at base is excluded and the work
#      is accepted; a test the change broke fails the work even against a Codex PASS.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SUPERVISOR_STATE_DIR="$(mktemp -d)"
. "$ROOT/bin/supervisor-lib.sh"
GATE="$ROOT/hooks/review-gate.sh"
export SUPERVISOR_CODEX_USAGE_CMD="/usr/bin/true"
export CODEX_SESSIONS_DIR="$(mktemp -d)"
RID="gate-rules-run-id"
pass=0; fail=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
no(){ echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }
FAKE="$(mktemp -d)"; CODEX_CALLED="$FAKE/called"
cat > "$FAKE/codex" <<'EOF'
if [ "${1:-}" = login ]; then echo "Logged in using ChatGPT"; exit 0; fi
if echo "$*" | grep -q "HANDOFF | BLOCKED"; then
  echo called >> "$CODEX_CALLED"
  echo "STATE: ${FAKE_STATE:-COMPLETE}"
  echo "VERDICT: ${FAKE_VERDICT:-PASS}"
  [ -n "${FAKE_FINDING:-}" ] && echo "1. ${FAKE_FINDING}"
  exit 0
else
  echo "VERDICT: PASS"
fi
EOF
chmod +x "$FAKE/codex"
export CODEX_CALLED
TR="$(mktemp)"; printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"text","text":"готово"}]}}' > "$TR"
REPOS=()
cleanup(){ rm -rf "$SUPERVISOR_STATE_DIR" "$FAKE" "$TR" ${REPOS[@]+"${REPOS[@]}"}; }
trap cleanup EXIT
mkcase(){
  PROJ="$(mktemp -d)"; REPOS+=("$PROJ")
  ( cd "$PROJ" && git init -q && git config user.email t@t && git config user.name t \
      && mkdir src && echo base > src/app.txt && git add -A && git commit -qm init >/dev/null )
  IDIR="$(instance_dir "$(slug_for "$PROJ")")"; mkdir -p "$IDIR"
  printf '%s\n' "$(canon_path "$PROJ")" > "$IDIR/project"
  printf '%s\n' "$RID" > "$IDIR/run-id"
  printf '%s\n' "$(git -C "$PROJ" rev-parse HEAD)" > "$IDIR/base-sha"
  rm -f "$SUPERVISOR_STATE_DIR"/rounds-* "$SUPERVISOR_STATE_DIR"/rounds-meta-* "$SUPERVISOR_STATE_DIR"/handoffs-* \
        "$SUPERVISOR_STATE_DIR"/misdeclared-* "$SUPERVISOR_STATE_DIR"/remediations-* 2>/dev/null || true
}
edit(){ echo "worker $RANDOM" >> "$PROJ/src/app.txt"; }
declare_outcome(){ # $1=result  $2=ts
  jq -nc --arg r "$1" --arg ts "$2" --arg rid "$RID" \
    '{schema:1, result:$r, summary:"done", ts:$ts, run_id:$rid}' > "$IDIR/outcome.json"
}
rungate(){ # $1=session_id ; FAKE_*/SUPERVISOR_* from the caller line
  rm -f "$CODEX_CALLED"
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$1" "$TR" "$PROJ" \
    | ORCHESTRATOR_RUN_ID="$RID" SUPERVISOR_VERIFIER_ENABLED=0 PATH="$FAKE:$PATH" "$GATE"
}
codex_calls(){ wc -l < "$CODEX_CALLED" 2>/dev/null | tr -d ' ' || echo 0; }
done_is(){ [ "$(cat "$IDIR/done" 2>/dev/null)" = "$1" ]; }
blocked(){ printf '%s' "$1" | grep -q '"decision": "block"'; }

echo "== 1. the same wrong declaration, three times =="
mkcase; edit
declare_outcome succeeded_research "2026-09-20 00:20:00"
out1=$(FAKE_STATE=COMPLETE FAKE_VERDICT=FAIL FAKE_FINDING="[acceptance_failure] not done" rungate r1)
check "first time: routed to a normal review (Codex asked)"   '[ -s "$CODEX_CALLED" ]'
check "first time: the review's FAIL blocks"                  'blocked "$out1"'
# The worker stops again WITHOUT declaring again: the old file is still there. Not a repeat.
out1b=$(FAKE_STATE=COMPLETE FAKE_VERDICT=FAIL FAKE_FINDING="[acceptance_failure] still not done" rungate r1)
check "a stop with the OLD declaration in place is not counted as a repeat (Codex asked again)" '[ -s "$CODEX_CALLED" ]'
declare_outcome succeeded_research "2026-09-20 00:45:00"
out2=$(FAKE_STATE=COMPLETE FAKE_VERDICT=FAIL FAKE_FINDING="[acceptance_failure] not done" rungate r1)
check "second declaration: blocked WITHOUT a Codex round"      '! [ -s "$CODEX_CALLED" ] && blocked "$out2"'
check "and told which outcome fits a non-empty diff"           'printf "%s" "$out2" | grep -q "succeeded_changes"'
check "not parked yet"                                         '[ ! -f "$IDIR/done" ]'
declare_outcome succeeded_research "2026-09-20 01:10:00"
out3=$(FAKE_STATE=COMPLETE FAKE_VERDICT=FAIL rungate r1)
check "third declaration: parked as needs-user"               'done_is needs-user'
check "with no Codex round spent on it"                        '! [ -s "$CODEX_CALLED" ]'
check "and the review record says why"                         'jq -r .findings "$IDIR/reports/review.json" | grep -q "3 times"'

echo "== 1b. an honest re-declaration resets nothing it should not =="
mkcase; edit
declare_outcome succeeded_no_change "2026-09-20 02:00:00"
out=$(FAKE_STATE=COMPLETE FAKE_VERDICT=PASS rungate r2)
check "first misdeclaration went to review"                   '[ -s "$CODEX_CALLED" ]'
declare_outcome succeeded_changes "2026-09-20 02:05:00"
out=$(FAKE_STATE=COMPLETE FAKE_VERDICT=PASS rungate r2)
check "declaring succeeded_changes afterwards is reviewed and passes" 'done_is passed'
check "and the misdeclaration counter is gone with the verdict" '[ ! -f "$SUPERVISOR_STATE_DIR/misdeclared-$RID" ]'

echo "== 2. handoffs are not failed rounds =="
mkcase; edit
out=$(FAKE_STATE=COMPLETE FAKE_VERDICT=FAIL FAKE_FINDING="[acceptance_failure] a" rungate r3); edit
out=$(FAKE_STATE=COMPLETE FAKE_VERDICT=FAIL FAKE_FINDING="[acceptance_failure] b" rungate r3); edit
check "two FAIL rounds recorded"                              '[ "$(cat "$SUPERVISOR_STATE_DIR/rounds-$RID")" = 2 ]'
out=$(FAKE_STATE=HANDOFF FAKE_VERDICT=N/A rungate r3)
check "the FIRST handoff after two FAILs is a nudge, not an escalation" 'blocked "$out" && [ ! -f "$IDIR/done" ]'
check "and it is counted as handoff 1"                        '[ "$(cat "$SUPERVISOR_STATE_DIR/handoffs-$RID")" = 1 ]'
check "the FAIL counter did not move"                         '[ "$(cat "$SUPERVISOR_STATE_DIR/rounds-$RID")" = 2 ]'
out=$(FAKE_STATE=HANDOFF FAKE_VERDICT=N/A rungate r3)
out=$(FAKE_STATE=HANDOFF FAKE_VERDICT=N/A rungate r3)
check "the third handoff escalates (cap is per handoffs)"     'done_is needs-user'

echo "== 3. a blocker is fresh for its dispatch only =="
mkcase; edit
jq -nc --arg id D-1 --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '{id:$id, at:$at, task:"first"}' > "$IDIR/dispatch.json"
jq -nc --arg ts "$(date -v-2H '+%F %T' 2>/dev/null || date -d '2 hours ago' '+%F %T')" --arg rid "$RID" \
  '{ts:$ts, class:"blocker", text:"хто відповідає на заявки?", run_id:$rid}' >> "$IDIR/findings.jsonl"
touch -A -010000 "$IDIR/dispatch.json"    # the dispatch is an hour old; the blocker two hours: older than it
out=$(FAKE_STATE=COMPLETE FAKE_VERDICT=PASS rungate r4)
check "a blocker filed before this dispatch does not park it"  'done_is passed'
mkcase; edit
jq -nc --arg id D-2 --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '{id:$id, at:$at, task:"second"}' > "$IDIR/dispatch.json"
sleep 1
jq -nc --arg ts "$(date '+%F %T')" --arg rid "$RID" \
  '{ts:$ts, class:"blocker", text:"потрібен доступ", run_id:$rid}' >> "$IDIR/findings.jsonl"
out=$(FAKE_STATE=COMPLETE FAKE_VERDICT=PASS rungate r5)
check "a blocker filed during this dispatch still parks it"    'done_is needs-user'

echo "== 4. nothing changed since the verdict ⇒ no second review =="
mkcase; edit
out=$(FAKE_STATE=COMPLETE FAKE_VERDICT=PASS rungate r6)
check "accepted"                                              'done_is passed && [ -s "$IDIR/done-digest" ]'
out=$(FAKE_STATE=COMPLETE FAKE_VERDICT=PASS rungate r6)
check "a second stop on the same tree asks Codex nothing"      '! [ -s "$CODEX_CALLED" ]'
check "and blocks nothing"                                     '! blocked "$out"'
edit
out=$(FAKE_STATE=COMPLETE FAKE_VERDICT=PASS rungate r6)
check "a changed tree is reviewed again"                       '[ -s "$CODEX_CALLED" ]'
rm -f "$IDIR/done"      # what a new director message does (worker-send)
out=$(FAKE_STATE=COMPLETE FAKE_VERDICT=PASS rungate r6)
check "a new message (done cleared) is reviewed again even on the same tree" '[ -s "$CODEX_CALLED" ]'

echo "== 5. nothing to verify is not a debt =="
mkcase; edit
# The real verifier on a repository with no recognised stack yields exactly one criterion:
# "no automated verification available for this stack", inconclusive.
out=$(FAKE_STATE=COMPLETE FAKE_VERDICT=PASS SUPERVISOR_VERIFIER_ENABLED=1 SUPERVISOR_VERIFY_STEP_TIMEOUT=60 SUPERVISOR_VERIFY_TOTAL_TIMEOUT=120 \
      bash -c 'printf "{\"session_id\":\"r7\",\"transcript_path\":\"%s\",\"cwd\":\"%s\",\"stop_hook_active\":false}" "$0" "$1" \
        | ORCHESTRATOR_RUN_ID="'"$RID"'" PATH="'"$FAKE"':$PATH" "'"$GATE"'"' "$TR" "$PROJ")
check "a PASS on a deliverable nothing can build or test is accepted" 'done_is passed'
check "not banked as debt"                                    '! done_is debt'
grep -q "nothing to build or test for this deliverable" "$SUPERVISOR_STATE_DIR/supervisor.log" \
  && ok "and the log says why" || no "the log does not explain the accepted PASS"

echo "== 6. through the gate itself: red at base is not the change's failure; a new red is =="
# The whole path, not the verifier alone: a repository with a shell suite, the REAL verifier under
# the REAL gate, Codex stubbed to PASS. One test is red at the base commit and untouched by the
# change; the gate must accept. Then the change breaks a second test; the gate must refuse, and say
# it was the verifier that refused.
PROJ="$(mktemp -d)"; REPOS+=("$PROJ")
mkdir -p "$PROJ/engine/bin" "$PROJ/engine/tests"
printf '#!/bin/bash\necho beta\n' > "$PROJ/engine/bin/beta.sh"
printf '#!/bin/bash\nHERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"\n[ "$(bash "$HERE/bin/beta.sh")" = beta ]\n' > "$PROJ/engine/tests/test-beta.sh"
printf '#!/bin/bash\n# red before this change and after it: not this change'"'"'s doing\nexit 1\n' > "$PROJ/engine/tests/test-always-red.sh"
chmod +x "$PROJ"/engine/bin/*.sh "$PROJ"/engine/tests/*.sh
( cd "$PROJ" && git init -q && git config user.email t@t && git config user.name t \
    && git add -A && git commit -qm base >/dev/null )
IDIR="$(instance_dir "$(slug_for "$PROJ")")"; mkdir -p "$IDIR"
printf '%s\n' "$(canon_path "$PROJ")" > "$IDIR/project"
printf '%s\n' "$RID" > "$IDIR/run-id"
printf '%s\n' "$(git -C "$PROJ" rev-parse HEAD)" > "$IDIR/base-sha"
rm -f "$SUPERVISOR_STATE_DIR"/rounds-* "$SUPERVISOR_STATE_DIR"/rounds-meta-* "$SUPERVISOR_STATE_DIR"/misdeclared-* 2>/dev/null || true
rungate_verified(){ # $1=session id — the real verifier runs (bounded), Codex is the stub
  rm -f "$CODEX_CALLED"
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$1" "$TR" "$PROJ" \
    | ORCHESTRATOR_RUN_ID="$RID" SUPERVISOR_VERIFIER_ENABLED=1 SUPERVISOR_TEST_SELECT=0 \
      SUPERVISOR_VERIFY_STEP_TIMEOUT=120 SUPERVISOR_VERIFY_TOTAL_TIMEOUT=240 SUPERVISOR_TEST_JOBS=2 \
      PATH="$FAKE:$PATH" "$GATE"
}
# (a) the change touches beta.sh harmlessly; test-always-red is red at base and now.
echo '# touched, behaviour unchanged' >> "$PROJ/engine/bin/beta.sh"
out=$(FAKE_STATE=COMPLETE FAKE_VERDICT=PASS rungate_verified g6a)
EVA="$(ls "$IDIR"/evidence/g6a/evidence.json 2>/dev/null)"
check "(a) the verifier ran through the gate and left evidence"   '[ -s "$EVA" ]'
check "(a) the red-at-base test is listed as excluded"             'jq -r ".criteria[].note" "$EVA" | grep -q "red at base too, excluded: test-always-red.sh"'
check "(a) the suite criterion passed"                             '[ "$(jq -r ".criteria[] | select(.criterion|startswith(\"shell suite\")) | .status" "$EVA")" = pass ]'
check "(a) the gate accepted the work"                             'done_is passed'
check "(a) no verifier override in the log"                        '! grep -q "VERIFIER OVERRIDE" "$SUPERVISOR_STATE_DIR/supervisor.log"'
# (b) the change breaks beta: a NEW red beside the old one.
rm -f "$IDIR/done" "$IDIR/done-digest"
echo 'echo broken' > "$PROJ/engine/bin/beta.sh"
out=$(FAKE_STATE=COMPLETE FAKE_VERDICT=PASS rungate_verified g6b)
EVB="$(ls "$IDIR"/evidence/g6b/evidence.json 2>/dev/null)"
check "(b) the suite criterion failed"                             '[ "$(jq -r ".criteria[] | select(.criterion|startswith(\"shell suite\")) | .status" "$EVB")" = fail ]'
check "(b) the note names the new failure and still excludes the old one" 'jq -r ".criteria[].note" "$EVB" | grep -q "new failures: test-beta.sh" && jq -r ".criteria[].note" "$EVB" | grep -q "red at base too (not counted): test-always-red.sh"'
check "(b) the gate refused although Codex said PASS"              'blocked "$out" && [ ! -f "$IDIR/done" ]'
check "(b) and it was the verifier that refused"                   'grep -q "VERIFIER OVERRIDE" "$SUPERVISOR_STATE_DIR/supervisor.log"'
check "(b) the refusal quotes the failing test"                    'printf "%s" "$out" | grep -q "test-beta.sh"'

echo
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ] || exit 1
