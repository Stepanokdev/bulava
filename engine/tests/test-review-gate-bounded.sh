#!/bin/bash
# §11.4 — bounded classified review (scoped runs). Stubs the reviewer (fake codex that
# emits STATE:/VERDICT: + a [class] finding) and asserts the bounded state machine:
#   • patch PASS → mark_done passed with no automatic product audit
#   • the same review ends the same way whether the request came from the app or a terminal
#   • acceptance_failure → exactly 1 remediation block, then needs-user (no round 3)
#   • scope_violation only → needs-user, disposition=scope_violation, no reopen
#   • harness_failure only → debt
#   • audit-mode empty/unreadable review → falls through to the inconclusive path,
#     never a false needs-user off a blank verdict (regression #10)
#   • all-out-of-scope run → scope-gate quarantines, empty-diff guard returns needs-user
#     with disposition=scope_violation, reviewer never invoked (regression #11)
#   • repo cleanliness: LEGACY_REPO_NOTES=0 keeps notes in the run dir only; =1 dual-writes
#     the repo copy too (regression #6)
#   • broad (no runspec) remains task-scoped and accepts PASS without a product audit
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SUPERVISOR_STATE_DIR="$(mktemp -d)"
. "$ROOT/bin/supervisor-lib.sh"
GATE="$ROOT/hooks/review-gate.sh"
# These suites are about the gate's own logic, not about this machine's quota. Left to itself the
# gate asks the real Codex CLI how much window is left, and a developer whose window happens to be
# near the guard would watch every one of these fail for a reason that has nothing to do with them.
export SUPERVISOR_CODEX_USAGE_CMD="/usr/bin/true"
export CODEX_SESSIONS_DIR="$(mktemp -d)"
RID="bounded-test-run-id"

pass=0; fail=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
no(){ echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

# Fake codex: the REVIEW prompt contains the STATE menu ("HANDOFF | BLOCKED"). Touches
# CODEX_CALLED so a test can prove the reviewer never ran. Parameterized via env.
FAKE="$(mktemp -d)"; CODEX_CALLED="$FAKE/called"
cat > "$FAKE/codex" <<'EOF'
#!/bin/bash
# Not a turn. The engine asks the real CLI this before spending a call, and a stub that
# treated it as a brief would record "login status" as the run's prompt and depth.
if [ "${1:-}" = login ]; then echo "Logged in using ChatGPT"; exit 0; fi
if echo "$*" | grep -q "HANDOFF | BLOCKED"; then
  : > "$CODEX_CALLED"
  [ -n "${FAKE_EMPTY:-}" ] && exit 0                       # simulate empty/unreadable review
  [ "${FAKE_STATE:-COMPLETE}" != NONE ]   && echo "STATE: ${FAKE_STATE:-COMPLETE}"
  [ "${FAKE_VERDICT:-PASS}" != NONE ]     && echo "VERDICT: ${FAKE_VERDICT:-PASS}"
  [ -n "${FAKE_FINDING:-}" ]              && echo "1. ${FAKE_FINDING}"
  # Said out loud, because the gate now reads it. The last `[ ]` above decided this stub's exit
  # code by accident — with no FAKE_FINDING it left a 1 behind — and a reviewer that prints a full
  # verdict and then fails is precisely what the gate must refuse. That refusal is the point; this
  # fixture is about the state machine, and its exit code was never meant to be part of it.
  exit "${FAKE_RC:-0}"
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

# Fresh repo + instance dir per case (isolated slug ⇒ isolated IDIR + state files).
mkcase(){
  PROJ="$(mktemp -d)"; REPOS+=("$PROJ")
  ( cd "$PROJ" && git init -q && git config user.email t@t && git config user.name t \
      && mkdir src && echo base > src/app.txt && echo base > root.txt \
      && git add -A && git commit -qm init >/dev/null )
  IDIR="$(instance_dir "$(slug_for "$PROJ")")"; mkdir -p "$IDIR"
  printf '%s\n' "$(canon_path "$PROJ")" > "$IDIR/project"
  printf '%s\n' "$RID" > "$IDIR/run-id"
  printf '%s\n' "$(git -C "$PROJ" rev-parse HEAD)" > "$IDIR/base-sha"
}
setspec(){ printf '%s' "$1" > "$IDIR/runspec.json"; }
inscope(){ echo "worker $RANDOM" >> "$PROJ/src/app.txt"; }        # matches write_paths src/**
outscope(){ echo "worker $RANDOM" >> "$PROJ/root.txt"; }          # outside src/**

# Run the gate. Verifier disabled for speed/determinism (bounded PASS ignores it anyway).
rungate(){ # $1=session_id ; extra FAKE_*/SUPERVISOR_* env from the caller line
  rm -f "$CODEX_CALLED"
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$1" "$TR" "$PROJ" \
    | ORCHESTRATOR_RUN_ID="$RID" SUPERVISOR_VERIFIER_ENABLED=0 PATH="$FAKE:$PATH" "$GATE"
}
# Every case here reuses one run id, so the gate's per-run counters (rounds, the no-progress meta,
# remediations, harness attempts) leak from case to case. A case about ROUND BEHAVIOUR has to start
# from zero or it is reading the previous case's history.
freshcounters(){ rm -f "$SUPERVISOR_STATE_DIR"/rounds-* "$SUPERVISOR_STATE_DIR"/remediations-* \
                       "$SUPERVISOR_STATE_DIR"/harness-* 2>/dev/null || true; }
done_is(){ [ "$(cat "$IDIR/done" 2>/dev/null)" = "$1" ]; }
disp(){ jq -r '.disposition // ""' "$IDIR/reports/review.json" 2>/dev/null; }

echo "== the receipt is restamped with the REAL verdict, not the worker's claim =="

# The receipt is written when the worker declares its outcome, before this gate has seen anything.
# A `succeeded_changes` declaration therefore says "awaiting review" — and only the gate can turn
# that into a verdict. Driven through the real hook, because the wiring (IDIR_SCOPE, BIN_DIR,
# mark_done) is where this can silently break.
mkcase; setspec '{"schema":1,"mode":"patch","write_paths":["src/**"]}'; inscope
mkdir -p "$IDIR/report"
jq -nc '{result:"succeeded_changes", summary:"зробив експорт", ts:"2026-08-05 21:00",
         branch:"night/x", project_name:"repo", diffstat:"", unblock:"", task:"",
         review:"pending", commits:[], findings:[]}' > "$IDIR/report/receipt.json"
python3 "$ROOT/bin/receipt-render.py" "$IDIR/report/report.html" < "$IDIR/report/receipt.json" >/dev/null 2>&1
check "before the gate: awaiting review"    'grep -q "Очікує перевірки" "$IDIR/report/report.html"'

out=$(FAKE_STATE=COMPLETE FAKE_VERDICT=PASS rungate p_receipt_pass)
check "after PASS: review recorded as passed" '[ "$(jq -r .review "$IDIR/report/receipt.json")" = passed ]'
check "after PASS: the page says done"        'grep -q "перевірена" "$IDIR/report/report.html"'
check "after PASS: no longer awaiting"        '! grep -q "Очікує перевірки" "$IDIR/report/report.html"'

# A refusal must say WHY. "Not accepted" with no reason is a verdict he cannot act on — the same
# defect as "Needs you" with nothing behind it.
mkcase; setspec '{"schema":1,"mode":"patch","write_paths":["src/**"]}'; inscope
mkdir -p "$IDIR/report"
jq -nc '{result:"succeeded_changes", summary:"зробив", ts:"2026-08-05 21:00", branch:"night/x",
         project_name:"repo", diffstat:"", unblock:"", task:"", review:"pending",
         commits:[], findings:[]}' > "$IDIR/report/receipt.json"
out=$(FAKE_STATE=COMPLETE FAKE_VERDICT=FAIL FAKE_FINDING="src/a.py — заглушка замість реалізації" rungate p_receipt_fail)
check "a refusal is recorded as failed"  '[ "$(jq -r .review "$IDIR/report/receipt.json")" != passed ]'
check "the refusal reaches the page"     'grep -q "Не прийнято\|не перевірено" "$IDIR/report/report.html"'
check "and it says why"                  'grep -q "Що сказала перевірка" "$IDIR/report/report.html"'

echo "== patch PASS → passed, review.json, NO deep-audit escalation (regression #4) =="
mkcase; setspec '{"schema":1,"mode":"patch","write_paths":["src/**"]}'; inscope
out=$(FAKE_STATE=COMPLETE FAKE_VERDICT=PASS rungate p_pass)
check "done = passed"                       'done_is passed'
check "not blocked"                         '! printf "%s" "$out" | grep -q "\"decision\""'
check "review.json disposition = passed"    '[ "$(disp)" = passed ]'
check "review.json exists"                  '[ -s "$IDIR/reports/review.json" ]'
check "NO deep-audit (audit-state marker absent)" '[ ! -f "$SUPERVISOR_STATE_DIR/audit-state-p_pass" ]'

echo "== acceptance_failure → 1 remediation, then needs-user (no round 3) =="
mkcase; setspec '{"schema":1,"mode":"patch","write_paths":["src/**"]}'
inscope; out1=$(FAKE_STATE=COMPLETE FAKE_VERDICT=FAIL FAKE_FINDING="[acceptance_failure] header missing" rungate p_rem)
check "round1 blocks (remediation)"         'printf "%s" "$out1" | grep -q "\"decision\": \"block\""'
check "round1 disposition = remediation"    '[ "$(disp)" = remediation ]'
check "remediation counter incremented to 1" '[ "$(cat "$SUPERVISOR_STATE_DIR/remediations-$RID" 2>/dev/null)" = 1 ]'
check "round1 did not mark done"            '[ ! -f "$IDIR/done" ]'
inscope; out2=$(FAKE_STATE=COMPLETE FAKE_VERDICT=FAIL FAKE_FINDING="[acceptance_failure] still missing" rungate p_rem)
check "round2 does NOT block (no round 3)"  '! printf "%s" "$out2" | grep -q "\"decision\""'
check "round2 done = needs-user"            'done_is needs-user'
check "remediation cap held at 1"           '[ "$(cat "$SUPERVISOR_STATE_DIR/remediations-$RID" 2>/dev/null)" = 1 ]'

echo "== scope_violation only → needs-user, disposition scope_violation, no reopen =="
mkcase; setspec '{"schema":1,"mode":"patch","write_paths":["src/**"]}'; inscope
out=$(FAKE_STATE=COMPLETE FAKE_VERDICT=FAIL FAKE_FINDING="[scope_violation] touched unrelated file" rungate p_scope)
check "not blocked (not reopened)"          '! printf "%s" "$out" | grep -q "\"decision\""'
check "done = needs-user"                   'done_is needs-user'
check "disposition = scope_violation"       '[ "$(disp)" = scope_violation ]'

echo "== harness_failure only → debt =="
mkcase; setspec '{"schema":1,"mode":"patch","write_paths":["src/**"]}'; inscope
out=$(FAKE_STATE=COMPLETE FAKE_VERDICT=FAIL FAKE_FINDING="[harness_failure] verifier crashed" rungate p_harn)
check "done = debt"                         'done_is debt'
check "disposition = debt"                  '[ "$(disp)" = debt ]'

echo "== audit-mode empty review → inconclusive path, NOT a false needs-user (regression #10) =="
# SCOPE_GATE=0 so the empty-diff guard does not preempt; the empty review must reach
# the inconclusive branch, which sits BEFORE the audit needs-user branch.
mkcase; setspec '{"schema":1,"mode":"audit","write_paths":[]}'; inscope
out=$(SUPERVISOR_SCOPE_GATE=0 FAKE_EMPTY=1 rungate a_empty)
check "empty review blocks (inconclusive)"  'printf "%s" "$out" | grep -q "\"decision\": \"block\""'
check "did NOT resolve needs-user off blank" '! done_is needs-user'
check "no done written at round 1"          '[ ! -f "$IDIR/done" ]'

echo "== all-out-of-scope run → empty-diff guard needs-user, reviewer never runs (regression #11) =="
mkcase; setspec '{"schema":1,"mode":"patch","write_paths":["src/**"]}'; outscope
out=$(rungate p_allout)
check "done = needs-user"                   'done_is needs-user'
check "disposition = scope_violation"       '[ "$(disp)" = scope_violation ]'
check "reviewer (codex) never invoked"      '[ ! -f "$CODEX_CALLED" ]'
check "out-of-scope root.txt was reverted"  '[ "$(cat "$PROJ/root.txt")" = base ]'

echo "== repo cleanliness: LEGACY_REPO_NOTES=0 keeps notes in run dir only (regression #6) =="
mkcase; setspec '{"schema":1,"mode":"patch","write_paths":["src/**"]}'; inscope
out=$(FAKE_STATE=BLOCKED FAKE_VERDICT=NONE SUPERVISOR_LEGACY_REPO_NOTES=0 rungate p_blk0)
check "blocked.md written to run dir"        '[ -s "$IDIR/reports/blocked.md" ]'
check "NO BLOCKED.md in the client repo"     '[ ! -f "$PROJ/BLOCKED.md" ]'
check "done = needs-user (BLOCKED parked)"   'done_is needs-user'

echo "== repo cleanliness: LEGACY_REPO_NOTES=1 dual-writes the repo copy too =="
mkcase; setspec '{"schema":1,"mode":"patch","write_paths":["src/**"]}'; inscope
out=$(FAKE_STATE=BLOCKED FAKE_VERDICT=NONE SUPERVISOR_LEGACY_REPO_NOTES=1 rungate p_blk1)
check "blocked.md in run dir"                '[ -s "$IDIR/reports/blocked.md" ]'
check "BLOCKED.md ALSO in repo (transition)" '[ -s "$PROJ/BLOCKED.md" ]'

echo "== broad PASS is task-scoped and never launches a product audit =="
mkcase; inscope                                                  # no setspec ⇒ broad
out=$(FAKE_STATE=COMPLETE FAKE_VERDICT=PASS rungate b_broad)
check "broad task review passes"                 'done_is passed'
check "no automatic audit state is written"     '[ ! -f "$SUPERVISOR_STATE_DIR/audit-state-b_broad" ]'

echo "== advisory product findings never go back to Claude, app or terminal =="
# The app is an interface, not a different product: the SAME review of the SAME work must end the
# same way whether the request was typed in Bulava or in a terminal. It did not — these rules used
# to live inside the bounded branch, which only the app's marker forced a chat into.
mkcase; touch "$IDIR/direct-chat"; inscope
out=$(FAKE_STATE=COMPLETE FAKE_VERDICT=FAIL FAKE_FINDING="[related_improvement] unrelated product backlog" rungate chat_advisory)
check "advisory-only FAIL does not reopen chat work" '! printf "%s" "$out" | grep -q "\"decision\""'
check "advisory-only FAIL is accepted as task PASS"  'done_is passed'
chat_disp="$(disp)"

mkcase; inscope                                                  # same case, started in a terminal
out=$(FAKE_STATE=COMPLETE FAKE_VERDICT=FAIL FAKE_FINDING="[related_improvement] unrelated product backlog" rungate term_advisory)
check "a terminal run does not reopen it either"    '! printf "%s" "$out" | grep -q "\"decision\""'
check "and reaches the same disposition"            '[ "$(disp)" = "$chat_disp" ] && done_is passed'

echo "== an untagged FAIL still goes back to the worker, in both =="
# The taxonomy is an instruction, not something the harness can enforce. A reviewer that ignores it
# must not have its unlabelled defects read as "nothing reopenable" — that would park a run on a
# real bug nobody classified.
mkcase; touch "$IDIR/direct-chat"; inscope; freshcounters
out=$(FAKE_STATE=COMPLETE FAKE_VERDICT=FAIL FAKE_FINDING="the search field keeps its state on exit" rungate chat_untagged)
check "untagged chat FAIL is sent back as work"     'printf "%s" "$out" | grep -q "\"decision\": \"block\""'
mkcase; inscope; freshcounters
out=$(FAKE_STATE=COMPLETE FAKE_VERDICT=FAIL FAKE_FINDING="the search field keeps its state on exit" rungate term_untagged)
check "untagged terminal FAIL is sent back too"     'printf "%s" "$out" | grep -q "\"decision\": \"block\""'

echo "== a chat FAIL gets the progress-aware loop, not one flat remediation =="
# Two rounds of a real acceptance failure in a chat. The second must still be work for Claude while
# the list of findings is shrinking — the terminal has always behaved this way.
mkcase; touch "$IDIR/direct-chat"; inscope; freshcounters
out=$(FAKE_STATE=COMPLETE FAKE_VERDICT=FAIL FAKE_FINDING="[acceptance_failure] the filter sheet is missing" rungate chat_rounds)
check "round 1 goes back to Claude"                 'printf "%s" "$out" | grep -q "\"decision\": \"block\""'
inscope
out=$(FAKE_STATE=COMPLETE FAKE_VERDICT=FAIL FAKE_FINDING="[acceptance_failure] the filter sheet is missing" rungate chat_rounds)
check "round 2 is still Claude's to fix"            'printf "%s" "$out" | grep -q "\"decision\": \"block\""'
check "and nobody was asked to look yet"            '! done_is needs-user'

echo "== audit mode + ZERO repo changes → done=needs-user + review.json, no codex round (fix 1) =="
# A compliant audit writes findings to \$IDIR/findings.jsonl and touches NOTHING in the repo.
# The empty-diff early-exit must RESOLVE it (needs-user), not bare-exit and hang forever.
mkcase; setspec '{"schema":1,"mode":"audit","write_paths":[]}'   # NO inscope ⇒ zero diff vs base
out=$(rungate a_zero)
check "not blocked"                          '! printf "%s" "$out" | grep -q "\"decision\""'
check "done = needs-user"                    'done_is needs-user'
check "review.json written"                  '[ -s "$IDIR/reports/review.json" ]'
check "review.json disposition = needs-user" '[ "$(disp)" = needs-user ]'
check "reviewer (codex) never invoked"       '[ ! -f "$CODEX_CALLED" ]'

echo "== broad (no runspec) does NOT create findings.jsonl (fix 2b) =="
# Reviewer emits an out-of-scope [related_improvement]; a broad/no-runspec run must NOT
# fold it into findings.jsonl (no backlog spawn). Scoped runs still fold (control below).
mkcase; inscope                                                  # no setspec ⇒ broad
out=$(FAKE_STATE=COMPLETE FAKE_VERDICT=PASS FAKE_FINDING="[related_improvement] extract shared helper" \
      rungate b_fold)
check "reviewer WAS invoked (broad still reviews)" '[ -f "$CODEX_CALLED" ]'
check "NO findings.jsonl for broad run"            '[ ! -f "$IDIR/findings.jsonl" ]'

echo "== scoped run STILL folds reviewer findings into findings.jsonl (fix 2b control) =="
mkcase; setspec '{"schema":1,"mode":"patch","write_paths":["src/**"]}'; inscope
out=$(FAKE_STATE=COMPLETE FAKE_VERDICT=PASS FAKE_FINDING="[related_improvement] extract shared helper" rungate p_fold)
check "findings.jsonl created for scoped run"        '[ -s "$IDIR/findings.jsonl" ]'
check "findings.jsonl holds the related_improvement" 'grep -q related_improvement "$IDIR/findings.jsonl"'

echo "== T3d: a FRESH 'blocker' finding parks needs-user, no review round, no set -u crash =="
mkcase                                                   # broad (no setspec); blocker-park runs in any mode
inscope
printf '{"class":"blocker","text":"needs prod creds","cwd":"%s","run_id":"%s"}\n' "$PROJ" "$RID" > "$IDIR/findings.jsonl"
outb=$(FAKE_STATE=COMPLETE FAKE_VERDICT=PASS rungate p_blk)
check "blocker: done = needs-user"                'done_is needs-user'
check "blocker: NOT blocked (no loop)"            '! printf "%s" "$outb" | grep -q "\"decision\""'
check "blocker: review.json disposition = needs-user" '[ "$(disp)" = needs-user ]'
check "blocker: codex NOT called (parked before review)" '[ ! -f "$CODEX_CALLED" ]'
# a STALE finding (different run_id) must NOT park — normal flow proceeds
mkcase; inscope
printf '{"class":"blocker","text":"old","cwd":"%s","run_id":"stale-run"}\n' "$PROJ" > "$IDIR/findings.jsonl"
outs=$(FAKE_STATE=COMPLETE FAKE_VERDICT=PASS rungate p_stale)
check "stale blocker finding is IGNORED (not parked as needs-user)" '! done_is needs-user'


echo "== a stale usage reading cannot finish a run as unreviewed debt =="
# Codex's own fallback scrapes a number out of a session log written hours ago and writes it down
# with the current timestamp. Read raw, a long-gone 99% looked current — and the gate ended the run
# as review DEBT on the strength of it, telling the director a limit was spent when it was not.
mkcase; setspec '{"mode":"broad"}'; inscope
jq -n --argjson ts "$(date +%s)" --argjson old "$(( $(date +%s) - 7200 ))" \
  '{ts:$ts, observed_at:$old, source:"session",
    five_hour:{used_percentage:99, resets_at:($ts - 600), window_minutes:300},
    seven_day:{used_percentage:99, resets_at:($ts - 600), window_minutes:10080}}' \
  > "$SUPERVISOR_STATE_DIR/codex-usage.json"
outs=$(SUPERVISOR_CODEX_USAGE_CMD=/usr/bin/true FAKE_STATE=COMPLETE FAKE_VERDICT=PASS rungate stale-usage)
check "a two-hour-old reading does not stop the reviewer being reached" '[ -e "$CODEX_CALLED" ]'
check "and the run is not written off as debt on an old number" '! done_is debt'
rm -f "$SUPERVISOR_STATE_DIR/codex-usage.json"

echo ""
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
