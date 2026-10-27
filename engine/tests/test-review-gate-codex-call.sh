#!/bin/bash
# The final review must reach Codex, and when Codex is not the one who did the work, the result says so.
#
# 27 Oct, a Cyrillic project: the gate parked a run five times in a row with "рецензент (codex)
# зупинився з кодом 2", the watchdog woke it each time because Codex's meter was healthy, and the
# run ended for the operator. codex.log had the reason all along — `error: invalid UTF-8 was
# detected in one or more arguments` — because the gate built its prompt with `head -c`, which cut a
# Cyrillic letter in half, and `codex exec` refuses an argument like that before it starts.
#
# Pinned here, through the real gate and a Codex stub that refuses broken argv exactly as clap does:
#   • a letter straddling every limit the gate cuts at still reaches Codex whole, and the review runs
#   • a byte already broken in the run's own files is escaped and named, not a reason to skip review
#   • a call the CLI refuses itself is not "unreachable": no pause, no owed review, no loop
#   • a reviewer that is genuinely away still parks, now with the reason instead of a bare code
#   • where Codex missed a step, the receipt, the run view, the journal and the task record say so
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SUPERVISOR_STATE_DIR="$(mktemp -d)"
. "$ROOT/bin/supervisor-lib.sh"
GATE="$ROOT/hooks/review-gate.sh"
export SUPERVISOR_CODEX_USAGE_CMD="/usr/bin/true"
export CODEX_SESSIONS_DIR="$(mktemp -d)"
RID="codex-call-run"

pass=0; fail=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
no(){ echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

FAKE="$(mktemp -d)"; CODEX_CALLED="$FAKE/called"; export CODEX_CALLED
# Codex as its argument parser behaves: any argument that is not UTF-8 refuses the whole call with
# clap's message and exit 2, before anything else happens.
cat > "$FAKE/codex" <<'EOF'
#!/bin/bash
if [ "${1:-}" = login ]; then echo "Logged in using ChatGPT"; exit 0; fi
for a in "$@"; do
  if ! printf '%s' "$a" | perl -MEncode -e 'binmode STDIN; local $/; my $s = <STDIN>; $s = "" unless defined $s;
         eval { Encode::decode("UTF-8", $s, Encode::FB_CROAK); 1 } or exit 1'; then
    printf 'error: invalid UTF-8 was detected in one or more arguments\n\nUsage: codex exec [OPTIONS] [PROMPT]\n       codex exec [OPTIONS] <COMMAND> [ARGS]\n\nFor more information, try %s.\n' "'--help'" >&2
    exit 2
  fi
done
prompt=""; for a in "$@"; do prompt="$a"; done
printf '%s' "$prompt" > "$CODEX_CALLED.prompt"
case "${FAKE_CODEX_MODE:-pass}" in
  badflag) printf "error: unexpected argument '--frobnicate' found\n\nUsage: codex exec [OPTIONS] [PROMPT]\n\nFor more information, try '--help'.\n" >&2; exit 2 ;;
  crash)   printf 'error: stream disconnected before completion\n' >&2; exit 1 ;;
esac
echo "STATE: COMPLETE"; echo "VERDICT: PASS"
EOF
chmod +x "$FAKE/codex"

REPOS=()
cleanup(){ rm -rf "$SUPERVISOR_STATE_DIR" "$FAKE" "$CODEX_SESSIONS_DIR" ${REPOS[@]+"${REPOS[@]}"}; }
trap cleanup EXIT

NOW="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
mkcase(){  # $1 = the task text [$2 = pipeline gates json]
  PROJ="$(mktemp -d)"; REPOS+=("$PROJ")
  ( cd "$PROJ" && git init -q && git config user.email t@t && git config user.name t \
      && printf 'artifacts/\n' > .gitignore && echo base > app.txt && git add -A && git commit -qm init >/dev/null )
  IDIR="$(instance_dir "$(slug_for "$PROJ")")"; mkdir -p "$IDIR"
  printf '%s\n' "$(canon_path "$PROJ")" > "$IDIR/project"
  printf '%s\n' "$RID" > "$IDIR/run-id"
  printf '%s\n' "$(git -C "$PROJ" rev-parse HEAD)" > "$IDIR/base-sha"
  : > "$IDIR/direct-chat"
  if [ -n "${2:-}" ]; then
    jq -nc --arg at "$NOW" --arg t "$1" --argjson g "$2" '{id:"disp-1", at:$at, task:$t, message_id:"msg-1", pipeline:"my-flow", pipeline_gates:$g}' > "$IDIR/dispatch.json"
  else
    jq -nc --arg at "$NOW" --arg t "$1" '{id:"disp-1", at:$at, task:$t, message_id:"msg-1", pipeline:"adaptive-peer"}' > "$IDIR/dispatch.json"
  fi
  TR="$PROJ.transcript.jsonl"; REPOS+=("$TR")
  say "готово"
  rm -f "$SUPERVISOR_STATE_DIR"/rounds-* "$SUPERVISOR_STATE_DIR"/unreachable-* "$SUPERVISOR_STATE_DIR"/outcome-nudge-* 2>/dev/null || true
}
say(){ jq -nc --arg t "$1" '{type:"assistant", message:{role:"assistant", content:[{type:"text", text:$t}]}}' > "$TR"; }
work(){ echo "worker $RANDOM" >> "$PROJ/app.txt"; }
rungate(){
  rm -f "$CODEX_CALLED.prompt" "$IDIR/done" "$IDIR/done-digest" 2>/dev/null
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "${1:-s1}" "$TR" "$PROJ" \
    | ORCHESTRATOR_RUN_ID="$RID" SUPERVISOR_VERIFIER_ENABLED=0 PATH="$FAKE:$PATH" "$GATE"
}
done_is(){ [ "$(cat "$IDIR/done" 2>/dev/null)" = "$1" ]; }
ev(){ jq -c --arg s "$1" --arg st "$2" 'select(.stage == $s and .state == $st)' "$IDIR/run-events.jsonl" 2>/dev/null | tail -1; }
prompt_valid(){ [ -s "$CODEX_CALLED.prompt" ] && text_is_utf8 < "$CODEX_CALLED.prompt"; }
ascii(){ printf 'a%.0s' $(seq 1 "$1"); }

echo "===== a letter on every limit the gate cuts at still reaches Codex whole ====="
# Claude's last message is cut at 4000 bytes and the plan at 6000: one Cyrillic letter straddles each.
mkcase "Виправ форму"; work
say "$(ascii 3999)Жовтень — останнє повідомлення"
{ ascii 5999; printf 'Ж план далі\n'; } > "$IDIR/plan.md"
out="$(rungate s-a)"
check "Codex was called and its argument was valid UTF-8" 'prompt_valid'
check "the review ran and passed"                         'done_is passed'
check "nothing was parked as an unreachable reviewer"     '[ ! -e "$(pause_file "$IDIR")" ] && [ ! -e "$IDIR/codex-owed.json" ]'
check "the letter that would have been cut is gone, not half of it" '! grep -q "Жовтень" "$CODEX_CALLED.prompt" && grep -q "$(ascii 3999)" "$CODEX_CALLED.prompt"'

echo "===== a byte broken at the source is escaped and named, and the review still happens ====="
mkcase "Виправ форму"; work
printf 'План: зроби форму \377\376 і перевір\n' > "$IDIR/plan.md"
out="$(rungate s-b)"
check "Codex still read it, as valid UTF-8"               'prompt_valid'
check "each broken byte is written out where it was, not lost" 'grep -qF "зроби форму \\xFF\\xFE і перевір" "$CODEX_CALLED.prompt"'
check "and the reviewer is told those spots are damaged"  'grep -q "NOTE FROM THE ENGINE: some bytes .*in: PLAN_TEXT" "$CODEX_CALLED.prompt"'
check "the log names the part that carried them"          'grep -q "not valid UTF-8 (in: PLAN_TEXT)" "$SUPERVISOR_STATE_DIR/supervisor.log"'
check "the run passed review"                             'done_is passed'

echo "===== a call the CLI refuses itself is not an absent reviewer ====="
mkcase "Виправ форму"; work
out="$(FAKE_CODEX_MODE=badflag rungate s-c)"
check "the run stops once, for a person"                  'done_is needs-user'
check "no pause on Codex — the watchdog has nothing to resume" '[ ! -e "$(pause_file "$IDIR")" ]'
check "no review is recorded as owed"                     '[ ! -e "$IDIR/codex-owed.json" ] && [ ! -e "$IDIR/review-pending" ]'
check "the unreachable count did not move"                '[ ! -e "$SUPERVISOR_STATE_DIR/unreachable-$RID" ]'
check "the reason is what the CLI said"                   'ev run needs-user | jq -r .note | grep -q "unexpected argument"'
check "…not its usage block"                              '! ev run needs-user | jq -r .note | grep -q "Usage:"'
check "and the whole stderr is kept with the run"         'grep -q "unexpected argument" "$IDIR/review-stderr.log"'
check "the shared codex.log says whose call it was"       'grep -q "\[review-gate\] .* run $RID — codex exited 2" "$CODEX_LOG"'

echo "===== a refusal after earlier unreachable attempts leaves nothing to resurrect it ====="
mkcase "Виправ форму"; work
out="$(FAKE_CODEX_MODE=crash rungate s-c1)"
check "the first, real failure parked the run on Codex"   '[ "$(pause_provider "$IDIR")" = codex ] && [ -e "$IDIR/review-pending" ]'
printf '{"since":1,"stage":"review","reason":"unknown"}\n' > "$(codex_away_file "$IDIR")"
out="$(FAKE_CODEX_MODE=badflag rungate s-c2)"
check "the refusal settles it once, for a person"        'done_is needs-user'
check "the old pause on Codex is gone"                    '[ ! -e "$(pause_file "$IDIR")" ]'
check "so is the server's away-clock and every owed marker" '[ ! -e "$(codex_away_file "$IDIR")" ] && [ ! -e "$IDIR/review-pending" ] && [ ! -e "$(codex_owed_file "$IDIR")" ] && [ ! -e "$IDIR/resume-pending" ]'
check "and the unreachable count is cleared"              '[ ! -e "$SUPERVISOR_STATE_DIR/unreachable-$RID" ]'

echo "===== a reviewer that is really away still parks — with its reason ====="
mkcase "Виправ форму"; work
out="$(FAKE_CODEX_MODE=crash rungate s-d)"
check "the run is parked, not finished"                   '[ ! -e "$IDIR/done" ] && [ -e "$IDIR/review-pending" ]'
check "the reason carries Codex's own words"              'grep -q "зупинився з кодом 1 — error: stream disconnected" "$SUPERVISOR_STATE_DIR/supervisor.log"'

echo "===== the report review gets the same treatment ====="
GATES_R='{"review":false,"reportReview":true,"reportMaxRounds":2,"research":true,"requiredSkills":[]}'
outcome(){ jq -nc --arg r "$1" --arg s "$2" --arg rid "$RID" --arg ts "$(date '+%F %T')" \
  '{schema:1, result:$r, summary:$s, ts:$ts, run_id:$rid, dispatch_id:"disp-1"}' > "$IDIR/outcome.json"; }
mkcase "$(ascii 5999)Ж дослідження ринку" "$GATES_R"
mkdir -p "$PROJ/artifacts/r1"; printf '<html><body><h1>Звіт</h1><p>Ринок.</p></body></html>' > "$PROJ/artifacts/r1/index.html"
outcome succeeded_research "Готово: artifacts/r1/index.html"
out="$(rungate s-e)"
check "a task cut at its 6000-byte limit still reaches the report reviewer whole" 'prompt_valid && done_is passed'
mkcase "Дослідження ринку" "$GATES_R"
mkdir -p "$PROJ/artifacts/r1"; printf '<html><body><h1>Звіт</h1></body></html>' > "$PROJ/artifacts/r1/index.html"
outcome succeeded_research "Готово: artifacts/r1/index.html"
out="$(FAKE_CODEX_MODE=badflag rungate s-f)"
check "a refused report review stops once, without a pause" 'done_is needs-user && [ ! -e "$(pause_file "$IDIR")" ] && [ ! -e "$IDIR/codex-owed.json" ]'

echo "===== where Codex missed a step, the result says so ====="
mkcase "Виправ форму"; work
codex_gap "$IDIR" preflight "codex зупинився з помилкою (код 1)"
# A gap from an earlier message of the same run is that message's business, not this one's.
jq -nc --arg rid "$RID" '{stage:"consultation", reason:"old", by:"claude", at:1, run_id:$rid, dispatch_id:"disp-0"}' >> "$(codex_gap_file "$IDIR")"
mkdir -p "$IDIR/report"
jq -nc --arg rid "$RID" '{result:"succeeded_changes", summary:"Зроблено", run_id:$rid, review:"pending", language:"Ukrainian"}' > "$IDIR/report/receipt.json"
out="$(rungate s-g)"
check "the work still passes — Codex did review it"       'done_is passed'
check "the receipt records partial participation"         '[ "$(jq -r .codex.status "$IDIR/report/receipt.json")" = partial ]'
check "with the step and the reason"                      '[ "$(jq -r ".codex.gaps[0].stage + \"|\" + .codex.gaps[0].reason" "$IDIR/report/receipt.json")" = "preflight|codex зупинився з помилкою (код 1)" ]'
check "an earlier message's gap is not counted"           '[ "$(jq ".codex.gaps | length" "$IDIR/report/receipt.json")" = 1 ]'
check "the receipt page shows it"                         'grep -q "Без Codex" "$IDIR/report/report.html"'
check "the run view's last word says it"                  'ev run passed | jq -r .note | grep -q "Без Codex: підготовка"'
check "the journal's terminal event carries it"           '[ "$(jq -r "select(.kind == \"terminal\" and .run_id == \"$RID\") | .codex.status" "$SUPERVISOR_STATE_DIR/decisions.jsonl" | tail -1)" = partial ]'

mkcase "Виправ форму"; work
out="$(rungate s-h)"
check "a run Codex took part in throughout reads as full" '[ "$(ev run passed | jq -r .codex.status)" = full ] && ! ev run passed | jq -r .note | grep -q "Codex"'

echo "===== a server's task record carries it to the bridge ====="
mkcase "Виправ форму"
task_create "PRJ-9" "$PROJ" youtrack bob "Виправ форму" "" "" >/dev/null 2>&1
printf 'PRJ-9\n' > "$IDIR/task-id"
task_attempt_begin PRJ-9 "$IDIR" disp-1 initial >/dev/null 2>&1
codex_gap "$IDIR" consultation "Codex не відповів за 900с"
task_on_terminal "$IDIR" passed
check "the task records how Codex took part"              '[ "$(task_get PRJ-9 .codex.status)" = partial ]'
check "so does the attempt"                               '[ "$(task_get PRJ-9 ".attempts[-1].codex.gaps[0].stage")" = consultation ]'

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
