#!/bin/bash
# A spent Codex window must PARK the run, not finish it.
#
# The bug, exactly: `review-gate.sh` compared the wait against six hours and, finding it longer,
# wrote a line into REVIEW-DEBT.md and marked the work done. The window that actually runs out is
# the WEEKLY one and its reset is days away — so the branch written for the rare long wall was the
# one that fired every time, and a night's work shipped unreviewed under a note nobody asked for.
#
#   «If codex has run into its limits, claude carries on without it. I would rather it did not
#    carry on automatically… by default I do not want it working without codex.»
#
# What is pinned here:
#   • an exhausted weekly window parks the run and writes NO `done` — the regression itself
#   • under a day it waits in silence; a day or more, or no reset at all, asks the director
#   • a permission must name the request that is open — a stale or foreign answer unlocks nothing
#   • his answer is consumed exactly once, and choosing Claude ends the wait it was about
#   • a Claude stand-in that touches the tree has its review thrown away, and the run stays parked
#   • an engine installed in two halves is detected before any of this is relied on
#
# Model calls are stubbed. Clocks, markers and the gate itself are real.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SUPERVISOR_STATE_DIR="$(mktemp -d)"
. "$ROOT/bin/supervisor-lib.sh"
GATE="$ROOT/hooks/review-gate.sh"
# This suite is about the gate's logic, not about this machine's quota: left alone the gate would
# ask the real CLI and a developer near their own guard would watch it fail for unrelated reasons.
export SUPERVISOR_CODEX_USAGE_CMD="/usr/bin/true"
export CODEX_SESSIONS_DIR="$(mktemp -d)"
RID="codex-pause-run"

pass=0; fail=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
no(){ echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

FAKE="$(mktemp -d)"

# The app's signing key, for real. `codex_decision_settle` verifies an answer with openssl against
# the public half the app publishes, so a fixture that wrote answers by hand would be testing a
# door that is no longer there.
KEYDIR="$(mktemp -d)"
openssl ecparam -name prime256v1 -genkey -noout -out "$KEYDIR/priv.pem" 2>/dev/null
openssl ec -in "$KEYDIR/priv.pem" -pubout -out "$SUPERVISOR_STATE_DIR/decision-key.pem" 2>/dev/null
answer() {   # $1=idir $2=request id $3=choice  — what the APP writes
  local sig rid did
  rid="$(tr -d '[:space:]' < "$1/run-id" 2>/dev/null)"
  did="$(jq -r '.id // empty' "$1/dispatch.json" 2>/dev/null)"
  printf '%s|%s|%s|%s' "$2" "$3" "$rid" "$did" > "$KEYDIR/payload"
  openssl dgst -sha256 -sign "$KEYDIR/priv.pem" -out "$KEYDIR/sig" "$KEYDIR/payload" 2>/dev/null
  sig="$(base64 < "$KEYDIR/sig" | tr -d '\n')"
  jq -n --arg id "$2" --arg c "$3" --arg s "$sig" \
    '{request_id:$id, choice:$c, signature:$s}' > "$1/codex-decision-answer.json"
}
unsigned_answer() {   # $1=idir $2=request id $3=choice — what a worker could write
  jq -n --arg id "$2" --arg c "$3" '{request_id:$id, choice:$c}' > "$1/codex-decision-answer.json"
}
sign_payload() {   # $1=payload → base64 DER, as the app makes it
  printf '%s' "$1" > "$KEYDIR/p2"
  openssl dgst -sha256 -sign "$KEYDIR/priv.pem" -out "$KEYDIR/s2" "$KEYDIR/p2" 2>/dev/null
  base64 < "$KEYDIR/s2" | tr -d '\n'
}

cat > "$FAKE/codex" <<'EOF'
#!/bin/bash
if [ "${1:-}" = login ]; then echo "Logged in using ChatGPT"; exit 0; fi
if echo "$*" | grep -q "HANDOFF | BLOCKED"; then
  : > "${CODEX_CALLED:-/dev/null}"
  [ -n "${FAKE_CODEX_EMPTY:-}" ] && exit "${FAKE_CODEX_RC:-0}"
  echo "STATE: COMPLETE"; echo "VERDICT: PASS"
  exit "${FAKE_CODEX_RC:-0}"
fi
EOF
chmod +x "$FAKE/codex"

# The stand-in. It reads its prompt on stdin, like the real `claude -p` does, and one variant
# writes a file — the only way to prove the read-only claim is a check rather than a flag.
cat > "$FAKE/claude" <<'EOF'
#!/bin/bash
cat >/dev/null
: > "${CLAUDE_CALLED:-/dev/null}"
[ -n "${FAKE_CLAUDE_WRITES:-}" ] && echo "tampered" >> "${FAKE_CLAUDE_WRITES}"
echo "STATE: COMPLETE"; echo "VERDICT: PASS"
EOF
chmod +x "$FAKE/claude"
export SUPERVISOR_CLAUDE_BIN="$FAKE/claude"
CODEX_CALLED="$FAKE/codex-called"; CLAUDE_CALLED="$FAKE/claude-called"
export CODEX_CALLED CLAUDE_CALLED

TR="$(mktemp)"; printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"text","text":"готово"}]}}' > "$TR"
REPOS=()
cleanup(){ rm -rf "$SUPERVISOR_STATE_DIR" "$FAKE" "$KEYDIR" "$TR" "$CODEX_SESSIONS_DIR" ${REPOS[@]+"${REPOS[@]}"}; }
trap cleanup EXIT

# Codex's meter, written where `provider_state` reads it. A weekly window at 100% is the wall that
# actually gets hit; the five-hour one is deliberately left with room, because the bug was that the
# code behaved as though the short window were the one running out.
codex_usage(){  # $1 = seconds until the weekly reset
  local now; now="$(date +%s)"
  jq -n --argjson ts "$now" --argjson r "$(( now + ${1:-432000} ))" \
    '{ts:$ts, observed_at:$ts, source:"cli",
      five_hour:{used_percentage:4,  resets_at:($ts + 900),  window_minutes:300},
      seven_day:{used_percentage:100, resets_at:$r, window_minutes:10080}}' \
    > "$SUPERVISOR_STATE_DIR/codex-usage.json"
}
codex_available(){
  local now; now="$(date +%s)"
  jq -n --argjson ts "$now" \
    '{ts:$ts, observed_at:$ts, source:"cli",
      five_hour:{used_percentage:4, resets_at:($ts + 900), window_minutes:300},
      seven_day:{used_percentage:9, resets_at:($ts + 432000), window_minutes:10080}}' \
    > "$SUPERVISOR_STATE_DIR/codex-usage.json"
}

mkcase(){
  PROJ="$(mktemp -d)"; REPOS+=("$PROJ")
  ( cd "$PROJ" && git init -q && git config user.email t@t && git config user.name t \
      && echo base > app.txt && git add -A && git commit -qm init >/dev/null )
  IDIR="$(instance_dir "$(slug_for "$PROJ")")"; mkdir -p "$IDIR"
  printf '%s\n' "$(canon_path "$PROJ")" > "$IDIR/project"
  printf '%s\n' "$RID" > "$IDIR/run-id"
  printf '%s\n' '{"id":"DISP-1","task":"робота"}' > "$IDIR/dispatch.json"
  printf '%s\n' "$(git -C "$PROJ" rev-parse HEAD)" > "$IDIR/base-sha"
  echo "worker $RANDOM" >> "$PROJ/app.txt"    # a real diff, so no empty-diff guard fires
  # Every case reuses one run id, so the gate's per-run counters would otherwise leak between them.
  rm -f "$SUPERVISOR_STATE_DIR/rounds-$RID" "$SUPERVISOR_STATE_DIR/unreachable-$RID" 2>/dev/null || true
}

rungate(){  # $1 = session id
  rm -f "$CODEX_CALLED" "$CLAUDE_CALLED"
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$1" "$TR" "$PROJ" \
    | ORCHESTRATOR_RUN_ID="$RID" SUPERVISOR_VERIFIER_ENABLED=0 PATH="$FAKE:$PATH" "$GATE" >/dev/null 2>&1
}

echo "===== a weekly window five days out parks the run instead of finishing it ====="
mkcase; codex_usage 432000
rungate s-week
check "no terminal result was written"            '[ ! -e "$IDIR/done" ]'
check "the run is parked, and on CODEX"           '[ "$(jq -r .provider "$IDIR/paused-for-limit.json" 2>/dev/null)" = codex ]'
check "the review is recorded as still owed"      '[ -e "$IDIR/review-pending" ]'
check "nothing was written to review debt"        '[ ! -s "$(run_reports_dir "$(slug_for "$PROJ")")/review-debt.md" ]'
check "the reviewer was never called"             '[ ! -e "$CODEX_CALLED" ]'
check "Codex absence is recorded on the run"      'codex_owed "$IDIR"'

echo "===== days away, so the director is asked ====="
check "a decision is open"                        'codex_decision_pending "$IDIR"'
check "it offers waiting and going on"            '[ "$(jq -rc .choices "$IDIR/codex-decision.json")" = "[\"wait\",\"claude\"]" ]'
check "it carries the reset it is about"          '[ "$(jq -r .resets_at "$IDIR/codex-decision.json")" -gt "$(date +%s)" ]'

echo "===== under a day it waits in silence ====="
mkcase; codex_usage 28800          # eight hours
rungate s-8h
check "still parked"                              '[ "$(jq -r .provider "$IDIR/paused-for-limit.json" 2>/dev/null)" = codex ]'
check "still not finished"                        '[ ! -e "$IDIR/done" ]'
check "nobody was woken for an eight-hour wait"   '! codex_decision_pending "$IDIR"'

echo "===== a permission has to name the question that is open ====="
mkcase; codex_usage 432000; rungate s-grant
QID="$(jq -r .id "$IDIR/codex-decision.json")"
answer "$IDIR" SOMEBODY-ELSES-REQUEST claude
check "a mismatched answer grants nothing"        '! codex_decision_settle "$IDIR" >/dev/null'
check "and it does not linger to be reused"       '[ ! -e "$IDIR/codex-decision-answer.json" ]'
check "the question is still standing"            'codex_decision_pending "$IDIR"'

answer "$IDIR" "$QID" nonsense
check "an answer that is not a choice grants nothing" '! codex_decision_settle "$IDIR" >/dev/null'

echo "===== his own answer is taken once, and ends the wait it was about ====="
answer "$IDIR" "$QID" claude
check "the choice is granted"                     '[ "$(codex_decision_settle "$IDIR")" = claude ]'
check "the pause it was about is lifted"          '[ ! -e "$IDIR/paused-for-limit.json" ]'
check "the question is closed"                    '! codex_decision_pending "$IDIR"'
check "the permission is readable once granted"   '[ "$(codex_fallback_choice "$IDIR")" = claude ]'

echo "===== choosing to wait closes the question without lifting the pause ====="
mkcase; codex_usage 432000; rungate s-wait
QID="$(jq -r .id "$IDIR/codex-decision.json")"
answer "$IDIR" "$QID" wait
check "waiting is a decision like any other"      '[ "$(codex_decision_settle "$IDIR")" = wait ]'
check "the question is closed"                    '! codex_decision_pending "$IDIR"'
check "and the run is still parked on Codex"      '[ "$(jq -r .provider "$IDIR/paused-for-limit.json" 2>/dev/null)" = codex ]'
check "nothing was substituted"                   '[ "$(codex_fallback_choice "$IDIR")" = wait ]'

echo "===== a standing question survives the pause being re-checked ====="
mkcase; codex_usage 432000; rungate s-recon
check "the question is open to begin with"        'codex_decision_pending "$IDIR"'
check "the pause holds against the live meter"    '[ "$(pause_reconcile "$IDIR")" = holds ]'
check "and the question is still there"           'codex_decision_pending "$IDIR"'
QID="$(jq -r .id "$IDIR/codex-decision.json")"
codex_decision_ask "$IDIR" review exhausted 0 "asked again"
check "asking again keeps the same request"       '[ "$(jq -r .id "$IDIR/codex-decision.json")" = "$QID" ]'

echo "===== and it belongs to this work only ====="
printf '%s\n' '{"id":"DISP-2","task":"інша робота"}' > "$IDIR/dispatch.json"
check "a permission from earlier work is refused" '! codex_fallback_choice "$IDIR" >/dev/null'
check "and is dropped rather than left lying"     '[ ! -e "$IDIR/codex-fallback.json" ]'

echo "===== a standing question is kept truthful, not left at the first guess ====="
# Seen for real: a call died with exit 1, the card said "Codex stopped with an error" and gave no
# time; four minutes later the meter came back with the actual answer — a spent window with a reset
# under an hour away — and nothing rewrote the card. He would have decided from the first guess.
mkcase; codex_available
FAKE_CODEX_EMPTY=1 FAKE_CODEX_RC=1 rungate s-stale-card
check "the first attempt raises a card"           'codex_decision_pending "$IDIR"'
check "and it says what it knew then"             '[ "$(jq -r .state "$IDIR/codex-decision.json")" = failed ]'
FIRST="$(jq -r .id "$IDIR/codex-decision.json")"
codex_usage 3000          # the meter comes back: a window, back in under an hour
rungate s-stale-card2
check "the card now names the real reason"        '[ "$(jq -r .state "$IDIR/codex-decision.json")" = exhausted ]'
check "and carries the reset it had learned"      '[ "$(jq -r .resets_at "$IDIR/codex-decision.json")" -gt "$(date +%s)" ]'
check "without minting a question he must re-read" '[ "$(jq -r .id "$IDIR/codex-decision.json")" = "$FIRST" ]'

echo "===== when the window comes back, the question about it goes ====="
# Walked into this one for real: Codex returned, the run resumed, and the card was still on screen
# asking whether to wait for a window that had already reset. The next press would have handed an
# available Codex's work to Claude for no reason.
mkcase; codex_usage 432000; rungate s-moot
check "the question is open while the wall stands" 'codex_decision_pending "$IDIR"'
codex_available
check "reconciling sees the window is back"       '[ "$(pause_reconcile "$IDIR")" = cleared-fresh ]'
check "and the question goes with it"             '! codex_decision_pending "$IDIR"'
# And the same when the reviewer is simply reached: a card asking whether to wait, while Codex is
# reading the diff, is a decision about nothing.
mkcase; codex_usage 432000; rungate s-moot2
check "asked again on the next wall"              'codex_decision_pending "$IDIR"'
codex_available; rungate s-moot3
check "reaching the reviewer closes it"           '! codex_decision_pending "$IDIR"'
check "and the work went through normally"        '[ "$(cat "$IDIR/done" 2>/dev/null)" = passed ]'

echo "===== a lost race over the marker does not lose the decision ====="
# The failure Codex named: `codex_decision_settle` drops the pause as it grants, that drop can lose
# a fingerprint race, and every later poll then stopped at `holds` before reaching the branch that
# acts on the permission — the choice recorded, and nothing ever done about it. Simulated here by
# granting and then putting the pause straight back.
mkcase; codex_usage 432000; rungate s-race
QID="$(jq -r .id "$IDIR/codex-decision.json")"
answer "$IDIR" "$QID" claude
codex_decision_settle "$IDIR" >/dev/null
pause_record "$IDIR" codex "$(( $(date +%s) + 3600 ))" "codex usage guard" s-race
check "the pause is standing again"               '[ -s "$IDIR/paused-for-limit.json" ]'
check "reconciling ends it on his decision"       '[ "$(pause_reconcile "$IDIR")" = cleared-by-director ]'
check "and the marker is gone"                    '[ ! -e "$IDIR/paused-for-limit.json" ]'

echo "===== an answer to a question about work that has been replaced grants nothing ====="
mkcase; codex_usage 432000; rungate s-stale
QID="$(jq -r .id "$IDIR/codex-decision.json")"
printf '%s\n' '{"id":"DISP-LATER","task":"інша робота"}' > "$IDIR/dispatch.json"
answer "$IDIR" "$QID" claude
check "the stale answer is refused"               '! codex_decision_settle "$IDIR" >/dev/null'
check "and no permission was minted for the new work" '! codex_fallback_choice "$IDIR" >/dev/null'

echo "===== once he has chosen Claude, Claude reviews — and is held to reading ====="
mkcase; codex_usage 432000; rungate s-fb
QID="$(jq -r .id "$IDIR/codex-decision.json")"
answer "$IDIR" "$QID" claude
codex_decision_settle "$IDIR" >/dev/null
rungate s-fb2
check "Claude did the reading"                    '[ -e "$CLAUDE_CALLED" ]'
check "Codex was not called for it"               '[ ! -e "$CODEX_CALLED" ]'
check "the work is accepted"                      '[ "$(cat "$IDIR/done" 2>/dev/null)" = passed ]'
check "the record names who actually reviewed"    '[ "$(jq -r .reviewer "$(run_reports_dir "$(slug_for "$PROJ")")/review.json" 2>/dev/null)" = claude ]'

echo "===== a stand-in that writes is not a reviewer ====="
mkcase; codex_usage 432000; rungate s-tamper
QID="$(jq -r .id "$IDIR/codex-decision.json")"
answer "$IDIR" "$QID" claude
codex_decision_settle "$IDIR" >/dev/null
FAKE_CLAUDE_WRITES="$PROJ/app.txt" rungate s-tamper2
check "its verdict is thrown away"                '[ "$(cat "$IDIR/done" 2>/dev/null)" != passed ]'
check "and the run is parked, not finished"       '[ ! -e "$IDIR/done" ]'

echo "===== a reviewer that cannot be reached is not a review round ====="
mkcase; codex_available
FAKE_CODEX_EMPTY=1 FAKE_CODEX_RC=142 rungate s-timeout
check "nothing was finished off a timeout"        '[ ! -e "$IDIR/done" ]'
check "the run parks and asks instead"            'codex_decision_pending "$IDIR"'
check "no round was counted against the work"     '[ ! -s "$SUPERVISOR_STATE_DIR/rounds-$RID" ]'

echo "===== a wait that keeps renewing itself still becomes his to end ====="
# Every reading says "back in eight hours", so the gate never asks — and the run stands still for
# days with nothing on screen to press. Measured from when the pause began, that is one wait.
mkcase; codex_usage 28800; rungate s-rolling
NOW="$(date +%s)"
check "nobody was asked at the start"             '! codex_wait_is_his "$IDIR" "$NOW"'
check "nor half a day in"                         '! codex_wait_is_his "$IDIR" "$(( NOW + 43200 ))"'
check "but a full day of standing still is his"   'codex_wait_is_his "$IDIR" "$(( NOW + 86400 ))"'
# And his answer restarts the clock, or he would be asked again on the very next poll.
QID="$(jq -r .id "$IDIR/codex-decision.json" 2>/dev/null || echo none)"
codex_decision_ask "$IDIR" review exhausted 0 "asked"
QID="$(jq -r .id "$IDIR/codex-decision.json")"
check "an open question is not asked twice"       '! codex_wait_is_his "$IDIR" "$(( NOW + 86400 ))"'
answer "$IDIR" "$QID" wait
codex_decision_settle "$IDIR" >/dev/null
SAID="$(jq -r .granted_at "$IDIR/codex-fallback.json")"
check "saying wait buys another day of quiet"     '! codex_wait_is_his "$IDIR" "$(( SAID + 86399 ))"'
check "and only another day"                      'codex_wait_is_his "$IDIR" "$(( SAID + 86400 ))"'
check "a Claude pause is never his to end this way" 'pause_record "$IDIR" claude "$(( NOW + 600 ))" x s-rolling && ! codex_wait_is_his "$IDIR" "$(( NOW + 200000 ))"'

echo "===== an engine installed in two halves is caught before it matters ====="
WS="$SUPERVISOR_STATE_DIR/worker-settings.json"
OLD="$FAKE/old-review-gate.sh"; printf '#!/bin/bash\n# an engine from before the pause existed\n' > "$OLD"
jq -n --arg c "'$OLD'" '{hooks:{Stop:[{matcher:"",hooks:[{type:"command",command:$c}]}]}}' > "$WS"
check "an older installed gate is seen as older"  '[ "$(installed_gate_protocol)" = 1 ]'
check "and it is reported rather than assumed"    'engine_protocol_gap | grep -q протокол'
jq -n --arg c "'$ROOT/hooks/review-gate.sh'" '{hooks:{Stop:[{matcher:"",hooks:[{type:"command",command:$c}]}]}}' > "$WS"
check "the gate shipped with this library agrees" '[ "$(installed_gate_protocol)" = "$SUPERVISOR_PROTOCOL" ]'
check "and raises nothing"                        '! engine_protocol_gap'

echo "===== a call that failed has no verdict, whatever it printed on the way down ====="
# The most dangerous shape of this failure is the one that looks like success: STATE: COMPLETE /
# VERDICT: PASS printed, then a non-zero exit — killed at the alarm, refused mid-stream for want of
# quota, or cut off by an expired login. It used to be accepted as a clean pass.
mkcase; codex_available
FAKE_CODEX_RC=1 rungate s-partial-pass
check "a PASS from a failed call is not a pass"   '[ "$(cat "$IDIR/done" 2>/dev/null)" != passed ]'
check "nothing was finished at all"               '[ ! -e "$IDIR/done" ]'
check "and the run parks and asks instead"        'codex_decision_pending "$IDIR"'
check "the card does not call an error a limit"   '[ "$(jq -r .state "$IDIR/codex-decision.json")" != exhausted ]'
mkcase; codex_available; rungate s-clean-pass
check "a PASS from a clean call still passes"     '[ "$(cat "$IDIR/done" 2>/dev/null)" = passed ]'

echo "===== the card names the actual failure, not a window ====="
mkcase; codex_available
FAKE_CODEX_EMPTY=1 FAKE_CODEX_RC=142 rungate s-state-timeout
check "a timeout is called a timeout"             '[ "$(jq -r .state "$IDIR/codex-decision.json")" = timeout ]'
check "and carries the reason it was given"       'jq -r .reason "$IDIR/codex-decision.json" | grep -q 480'
mkcase; codex_available
# Saying nothing through a clean exit is a poor answer, not a missing reviewer: it costs the work a
# round, exactly as it did before, and only the cap turns it into a question for the director.
FAKE_CODEX_EMPTY=1 FAKE_CODEX_RC=0 rungate s-state-silent
check "one silent answer is a round, not a park"  '! codex_decision_pending "$IDIR"'
FAKE_CODEX_EMPTY=1 FAKE_CODEX_RC=0 rungate s-state-silent
FAKE_CODEX_EMPTY=1 FAKE_CODEX_RC=0 rungate s-state-silent
check "silence is called silence at the cap"      '[ "$(jq -r .state "$IDIR/codex-decision.json")" = silent ]'
check "and it was never written off as debt"      '[ "$(cat "$IDIR/done" 2>/dev/null)" != debt ]'

echo "===== preparation does not start a hand short ====="
mkcase
ENV="$IDIR/env.json"; jq -n '{seq:"1", pipeline:"dispatch", message:"робота"}' > "$ENV"
PLAIN="$IDIR/plain.json"; jq -n '{seq:"1", pipeline:"plain", message:"питання"}' > "$PLAIN"
check "a two-position pipeline needs Codex"       'codex_needed_for "$ENV"'
check "a plain chat message does not"             '! codex_needed_for "$PLAIN"'
codex_available
check "nothing is held while Codex is free"       '! prep_blocked_reason "$IDIR" 1 >/dev/null'
codex_usage 432000
check "a spent window holds the message"          '[ "$(prep_blocked_reason "$IDIR" 1)" = codex ]'
check "but never a plain chat message"            '! prep_blocked_reason "$IDIR" 0 >/dev/null'
printf '%s\n' '{"id":"DISP-1","task":"робота"}' > "$IDIR/dispatch.json"
codex_decision_ask "$IDIR" preparation exhausted 0 "вікно вичерпано"
answer "$IDIR" "$(jq -r .id "$IDIR/codex-decision.json")" claude
codex_decision_settle "$IDIR" >/dev/null
check "and his permission lifts the hold"         '! prep_blocked_reason "$IDIR" 1 >/dev/null'
rm -f "$IDIR/codex-fallback.json"

echo "===== an older installed gate stops the work before it starts ====="
WS="$SUPERVISOR_STATE_DIR/worker-settings.json"
OLD="$FAKE/old-review-gate.sh"; printf '#!/bin/bash\n# an engine from before the pause existed\n' > "$OLD"
jq -n --arg c "'$OLD'" '{hooks:{Stop:[{matcher:"",hooks:[{type:"command",command:$c}]}]}}' > "$WS"
codex_available
check "a mismatched engine holds the message"     '[ "$(prep_blocked_reason "$IDIR" 1)" = engine-mismatch ]'
check "and it outranks an available Codex"        '[ "$(prep_blocked_reason "$IDIR" 1)" != codex ]'
jq -n --arg c "'$ROOT/hooks/review-gate.sh'" '{hooks:{Stop:[{matcher:"",hooks:[{type:"command",command:$c}]}]}}' > "$WS"
check "a matching engine holds nothing"           '! prep_blocked_reason "$IDIR" 1 >/dev/null'

echo "===== the control state is not writable from a shell ====="
GATE_W="$ROOT/hooks/write-gate.sh"
bashcall() {  # $1 = the command the worker would run
  jq -n --arg c "$1" --arg cwd "$PROJ" \
    '{tool_name:"Bash", cwd:$cwd, tool_input:{command:$c}}' \
    | ORCHESTRATOR_RUN_ID="$RID" bash "$GATE_W" 2>/dev/null
}
denied() { printf '%s' "$1" | grep -q '"deny"'; }
check "granting itself the fallback is refused"   'denied "$(bashcall "echo x > \"$IDIR/codex-fallback.json\"")"'
check "answering its own question is refused"     'denied "$(bashcall "printf %s {} > $IDIR/codex-decision-answer.json")"'
check "so is erasing the pause"                   'denied "$(bashcall "rm -f $IDIR/paused-for-limit.json")"'
check "so is faking a finished review"            'denied "$(bashcall "mv /tmp/x $IDIR/review-pending")"'
check "reading them is still allowed"             '! denied "$(bashcall "cat $IDIR/codex-decision.json")"'
# Half the reads in this engine send stderr to /dev/null, and that contains a `>`. Refusing those
# would be a gate that denies looking.
check "a read that silences stderr is a read"     '! denied "$(bashcall "jq -r .id $IDIR/codex-decision.json 2>/dev/null")"'
check "and so is a grep that reports what it found" '! denied "$(bashcall "grep -q x $IDIR/review-pending && echo yes")"'
check "and so is ordinary work"                   '! denied "$(bashcall "echo hello > $PROJ/app.txt")"'
check "the engine own handles still work"         '! denied "$(bashcall "$IDIR/report-finding blocker \"нема доступу\"")"'
check "declaring an outcome still works"          '! denied "$(bashcall "$IDIR/report-outcome succeeded_changes готово")"'
# Naming the handles as an exemption would have made them a password.
check "a handle named in a comment is no password" 'denied "$(bashcall "echo x > $IDIR/codex-fallback.json # report-finding")"'
check "a loop is not mistaken for a write"        '! denied "$(bashcall "for f in a b; do echo \$f; done")"'
# A name the product might genuinely use. Denying those would block ordinary work in the name of
# guarding files that are nowhere near them.
check "the project's own answer.json is not ours" '! denied "$(bashcall "echo {} > $PROJ/fixtures/answer.json")"'
check "but the run's answer.json is"              'denied "$(bashcall "echo {} > $IDIR/answer.json")"'
check "and the worker's own notes stay writable"  '! denied "$(bashcall "echo note >> $IDIR/decisions.md")"'

echo "===== the app dispatch is held on the same rule as the chat pump ====="
# Two entry points into the same preparation, and only one of them used to be guarded. A dispatch
# started from the app is a person sitting in front of it, so it waits here rather than going in a
# hand short — and it stops waiting the moment he says to.
PI="$ROOT/bin/prepare-and-inject.sh"
mkcase; codex_usage 432000
TF="$IDIR/task.txt"; printf 'робота\n' > "$TF"
printf '%s\n' '{"id":"DISP-1","task":"робота"}' > "$IDIR/dispatch.json"
SUPERVISOR_PREP_HOLD_POLL=1 ORCHESTRATOR_RUN_ID="$RID" \
  bash "$PI" "$ROOT/bin" "$PROJ" fake-session "$SUPERVISOR_STATE_DIR" "$TF" "$IDIR" DISP-1 \
  >/dev/null 2>&1 &
_pi=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$IDIR/codex-decision.json" ] && break; sleep 0.4; done
check "holding raises the card straight away"     '[ -s "$IDIR/codex-decision.json" ]'
check "and says it is about Codex"                '[ "$(jq -r .provider "$IDIR/codex-decision.json")" = codex ]'
check "at the preparation stage, not the review"  '[ "$(jq -r .stage "$IDIR/codex-decision.json")" = preparation ]'
# Every field, because the last version of this test checked `provider` and `stage` — the two that
# happened to be right — and a dropped argument put the epoch into `state`, the sentence into
# `resets_at` and nothing at all into `reason`. The card said gibberish and the test was green.
check "the state is a state, not a timestamp"     '[ "$(jq -r .state "$IDIR/codex-decision.json")" = exhausted ]'
check "the reset is a time in the future"         '[ "$(jq -r .resets_at "$IDIR/codex-decision.json")" -gt "$(date +%s)" ]'
check "and the reason is a sentence, not empty"   'jq -r .reason "$IDIR/codex-decision.json" | grep -qi недоступний'
# The hold has no cap by design — the first version gave up after eight hours and prepared anyway,
# which is the automatic bypass this whole change removes. So it is still holding, and it says so
# on disk where the watchdog can pick the wait up if this process dies.
check "it is still holding, with no way out but him" 'kill -0 "$_pi" 2>/dev/null'
check "and the hold is written down, not just held"  '[ "$(jq -r .dispatch_id "$IDIR/dispatch-held.json" 2>/dev/null)" = DISP-1 ]'
# His answer ends it, and nothing else had to.
answer "$IDIR" "$(jq -r .id "$IDIR/codex-decision.json")" claude
_freed=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do kill -0 "$_pi" 2>/dev/null || { _freed=1; break; }; sleep 0.5; done
check "his decision is what lets it through"      '[ "$_freed" = 1 ]'
wait "$_pi" 2>/dev/null || true
rm -f "$IDIR/dispatch-held.json" 2>/dev/null || true

# Superseded while it waits: nothing is prepared and nothing is injected.
mkcase; codex_usage 432000
TF="$IDIR/task.txt"; printf 'робота\n' > "$TF"
printf '%s\n' '{"id":"DISP-1","task":"робота"}' > "$IDIR/dispatch.json"
SUPERVISOR_PREP_HOLD_POLL=1 ORCHESTRATOR_RUN_ID="$RID" \
  bash "$PI" "$ROOT/bin" "$PROJ" fake-session "$SUPERVISOR_STATE_DIR" "$TF" "$IDIR" DISP-1 \
  >/dev/null 2>&1 &
_pi=$!
sleep 1.5
printf '%s\n' '{"id":"DISP-2","task":"інша"}' > "$IDIR/dispatch.json"
_ended=0
for _ in 1 2 3 4 5 6 7 8; do kill -0 "$_pi" 2>/dev/null || { _ended=1; break; }; sleep 0.5; done
check "a superseded dispatch stops waiting"       '[ "$_ended" = 1 ]'
wait "$_pi" 2>/dev/null || true

echo "===== an answer is only an answer if the app signed it ====="
# Everything else in this handshake is a file, and a file is something the worker can write. This
# is the part it cannot forge: the private half lives in the app's keychain.
mkcase; codex_usage 432000; rungate s-sig
QID="$(jq -r .id "$IDIR/codex-decision.json")"
unsigned_answer "$IDIR" "$QID" claude
check "an unsigned answer grants nothing"         '! codex_decision_settle "$IDIR" >/dev/null'
check "and no permission was minted"              '! codex_fallback_choice "$IDIR" >/dev/null'
check "the question is still standing"            'codex_decision_pending "$IDIR"'
# A signature over a DIFFERENT decision does not carry over to this one.
answer "$IDIR" "$QID" wait
_wrong="$(jq -r .signature "$IDIR/codex-decision-answer.json")"
jq -n --arg id "$QID" --arg s "$_wrong" '{request_id:$id, choice:"claude", signature:$s}' \
  > "$IDIR/codex-decision-answer.json"
check "a signature for another choice is refused" '! codex_decision_settle "$IDIR" >/dev/null'
answer "$IDIR" "$QID" claude
check "and the real one is taken"                 '[ "$(codex_decision_settle "$IDIR")" = claude ]'
# No published key at all means the app has never run here; an answer arriving first is not one it sent.
mkcase; codex_usage 432000; rungate s-nokey
QID="$(jq -r .id "$IDIR/codex-decision.json")"
answer "$IDIR" "$QID" claude
mv "$SUPERVISOR_STATE_DIR/decision-key.pem" "$KEYDIR/stash.pem"
check "with no key to verify against, nothing passes" '! codex_decision_settle "$IDIR" >/dev/null'
mv "$KEYDIR/stash.pem" "$SUPERVISOR_STATE_DIR/decision-key.pem"

echo "===== a forgery cannot prove itself, however it was written ====="
GUARD="$ROOT/hooks/control-guard.sh"
guardcall() {  # $1 = PreToolUse | PostToolUse
  jq -n --arg e "$1" --arg cwd "$PROJ" \
    '{hook_event_name:$e, tool_name:"Bash", cwd:$cwd, tool_input:{command:"…"}}' \
    | ORCHESTRATOR_RUN_ID="$RID" bash "$GUARD" 2>/dev/null
}
mkcase; codex_usage 432000; rungate s-guard
QID="$(jq -r .id "$IDIR/codex-decision.json")"
answer "$IDIR" "$QID" claude; codex_decision_settle "$IDIR" >/dev/null
check "the permission is in place to begin with"  '[ "$(codex_fallback_choice "$IDIR")" = claude ]'
guardcall PreToolUse
check "the guard took a fingerprint"              '[ -s "$IDIR/.control-fp" ]'
# The two spellings the reviewer named, and neither is matched by name or by redirect operator:
# a filename assembled at runtime, written through a stream the filter does not parse.
_f=codex-fall; printf 'x' > "$IDIR/${_f}back.json"
guardcall PostToolUse >/dev/null
# The name was assembled at runtime and the write went through a stream no filter parses, so
# neither the text filter nor a fingerprint over that file is what saves this. Verification is:
# the thing it wrote cannot prove where it came from, so it is not a permission at whatever hour
# it was written, by whatever process, before or after any hook.
check "what it wrote cannot pass as a permission" '! codex_fallback_choice "$IDIR" >/dev/null'
check "and is dropped rather than left lying"     '[ ! -e "$IDIR/codex-fallback.json" ]'
# And the director's own answer still works, because a signature is all that was ever required.
codex_decision_ask "$IDIR" review exhausted 0 "перепитано"
QID="$(jq -r .id "$IDIR/codex-decision.json")"
answer "$IDIR" "$QID" claude
check "his signed answer still grants"            '[ "$(codex_decision_settle "$IDIR")" = claude ]'
guardcall PreToolUse; guardcall PostToolUse >/dev/null
check "an ordinary command marks nothing"         '! control_tampered "$IDIR"'
check "and the permission survives it"            '[ "$(codex_fallback_choice "$IDIR")" = claude ]'

echo "===== …and the text filter no longer has the hole it was told about ====="
check "&> is a write, not a stderr redirect"      'denied "$(bashcall "printf x &>$IDIR/codex-decision-answer.json")"'
check "2> is still only stderr"                   '! denied "$(bashcall "cat $IDIR/codex-decision.json 2>/dev/null")"'

echo "===== a permission has to prove itself every time it is used ====="
# Verifying only when the answer arrived left the grant as an ordinary unsigned file: whatever
# wrote it afterwards — a background shell that outlived the tool call — was believed ever after.
mkcase; codex_usage 432000; rungate s-forge
QID="$(jq -r .id "$IDIR/codex-decision.json")"
answer "$IDIR" "$QID" claude
check "an honest permission is granted"           '[ "$(codex_decision_settle "$IDIR")" = claude ]'
check "and reads back as one"                     '[ "$(codex_fallback_choice "$IDIR")" = claude ]'
# Now write the grant by hand, exactly as a background process could, after every hook has run.
jq -n --arg id "$QID" --arg rid "$RID" \
  '{request_id:$id, choice:"claude", granted_at:1, run_id:$rid, dispatch_id:"DISP-1"}' \
  > "$IDIR/codex-fallback.json"
check "a hand-written permission is refused"      '! codex_fallback_choice "$IDIR" >/dev/null'
check "and is removed rather than left lying"     '[ ! -e "$IDIR/codex-fallback.json" ]'
# A real signature, replayed against different work, is not a decision about this work.
answer "$IDIR" "$QID" claude; codex_decision_settle "$IDIR" >/dev/null
SIG="$(jq -r .signature "$IDIR/codex-fallback.json")"
printf '%s\n' '{"id":"DISP-OTHER","task":"інша робота"}' > "$IDIR/dispatch.json"
jq -n --arg id "$QID" --arg s "$SIG" --arg rid "$RID" \
  '{request_id:$id, choice:"claude", granted_at:1, run_id:$rid, dispatch_id:"DISP-OTHER", signature:$s}' \
  > "$IDIR/codex-fallback.json"
check "a signature from other work does not carry" '! codex_fallback_choice "$IDIR" >/dev/null'

echo "===== the guard no longer calls the ordinary end of a run forgery ====="
# The regression this replaces: `report-outcome` is a handle the worker MUST run, it writes
# outcome.json, and the guard called that tampering — deleting the director's own permission at
# the exact moment the run was finishing correctly.
mkcase; codex_usage 432000; rungate s-outcome
QID="$(jq -r .id "$IDIR/codex-decision.json")"
answer "$IDIR" "$QID" claude; codex_decision_settle "$IDIR" >/dev/null
guardcall PreToolUse
printf '%s\n' '{"result":"succeeded_changes","run_id":"'"$RID"'"}' > "$IDIR/outcome.json"
printf 'passed\n' > "$IDIR/done"
guardcall PostToolUse >/dev/null
check "declaring an outcome is not tampering"     '! control_tampered "$IDIR"'
check "and the permission survives it"            '[ "$(codex_fallback_choice "$IDIR")" = claude ]'
# And the app answering during a long command is not tampering either.
guardcall PreToolUse
answer "$IDIR" "$QID" wait
guardcall PostToolUse >/dev/null
check "an answer arriving mid-command is fine"    '! control_tampered "$IDIR"'
# What IS watched: the key the signatures are checked against.
guardcall PreToolUse
openssl ecparam -name prime256v1 -genkey -noout -out "$KEYDIR/evil.pem" 2>/dev/null
openssl ec -in "$KEYDIR/evil.pem" -pubout -out "$SUPERVISOR_STATE_DIR/decision-key.pem" 2>/dev/null
guardcall PostToolUse >/dev/null
check "swapping the trusted key is"               'control_tampered "$IDIR"'
check "and nothing is trusted while it stands"    '! codex_fallback_choice "$IDIR" >/dev/null'
openssl ec -in "$KEYDIR/priv.pem" -pubout -out "$SUPERVISOR_STATE_DIR/decision-key.pem" 2>/dev/null
check "the key file cannot be written from a shell" 'denied "$(bashcall "echo x > $SUPERVISOR_STATE_DIR/decision-key.pem")"'

echo "===== turning the review off has to prove it was him ====="
# It was an empty marker, and an empty marker proves nothing: anything able to write a file could
# finish a night unreviewed with the journal recording it as his decision. A helper script carries
# its payload out of reach of any command-text matching, so the marker itself has to be signed.
mkcase; codex_available
SLUG="$(slug_for "$PROJ")"
: > "$IDIR/review-off"                    # exactly what a worker could leave lying about
check "an empty marker authorises nothing"        '! review_off_authorised "$IDIR" "$SLUG"'
check "and is removed rather than left"           '[ ! -e "$IDIR/review-off" ]'
jq -n '{signature:"bm90LWEtc2lnbmF0dXJl", at:1}' > "$IDIR/review-off"
check "nor does a made-up signature"              '! review_off_authorised "$IDIR" "$SLUG"'
# The same signature, but for somebody else's project.
jq -n --arg s "$(sign_payload "review-off|some-other-project")" '{signature:$s}' > "$IDIR/review-off"
check "nor one signed for another project"        '! review_off_authorised "$IDIR" "$SLUG"'
# And the real thing, as the app writes it.
jq -n --arg s "$(sign_payload "review-off|$SLUG")" '{signature:$s, at:1}' > "$IDIR/review-off"
check "his own setting is honoured"               'review_off_authorised "$IDIR" "$SLUG"'
# End to end: a worker-made marker does not finish the run, a real one does.
rm -f "$IDIR/review-off"; : > "$IDIR/review-off"
rungate s-reviewoff-forged
check "a forged marker does not end the run unreviewed" '[ "$(cat "$IDIR/done" 2>/dev/null)" != debt ]'
mkcase; codex_available
SLUG="$(slug_for "$PROJ")"
jq -n --arg s "$(sign_payload "review-off|$SLUG")" '{signature:$s, at:1}' > "$IDIR/review-off"
rungate s-reviewoff-real
check "his real setting still ends it as debt"    '[ "$(cat "$IDIR/done" 2>/dev/null)" = debt ]'

echo "===== swapping the trusted key invalidates what it verified ====="
mkcase; codex_usage 432000; rungate s-keyswap
QID="$(jq -r .id "$IDIR/codex-decision.json")"
answer "$IDIR" "$QID" claude; codex_decision_settle "$IDIR" >/dev/null
check "the permission stands under his key"       '[ "$(codex_fallback_choice "$IDIR")" = claude ]'
check "and it remembers which key that was"       '[ -n "$(jq -r .key "$IDIR/codex-fallback.json")" ]'
openssl ecparam -name prime256v1 -genkey -noout -out "$KEYDIR/evil2.pem" 2>/dev/null
openssl ec -in "$KEYDIR/evil2.pem" -pubout -out "$SUPERVISOR_STATE_DIR/decision-key.pem" 2>/dev/null
check "a swapped key voids the permission"        '! codex_fallback_choice "$IDIR" >/dev/null'
# …and one minted under the swapped key dies when the app puts its own back — which it does on
# every refresh, so the window is seconds rather than for ever.
QID2=SELFMADE
jq -n --arg id "$QID2" --arg rid "$RID" --arg k "$(shasum -a 1 "$SUPERVISOR_STATE_DIR/decision-key.pem" | awk '{print $1}')" \
   '{request_id:$id, choice:"claude", granted_at:1, run_id:$rid, dispatch_id:"DISP-1", key:$k, signature:"x"}' \
   > "$IDIR/codex-fallback.json"
openssl ec -in "$KEYDIR/priv.pem" -pubout -out "$SUPERVISOR_STATE_DIR/decision-key.pem" 2>/dev/null
check "and what it minted dies with it"           '! codex_fallback_choice "$IDIR" >/dev/null'

echo "===== deleting the fingerprint is not a quiet pass ====="
# The named bypass: a helper script swaps the key, writes its own permission and removes
# `.control-fp`, and PostToolUse used to exit 0 for want of anything to compare.
mkcase; codex_available
guardcall PreToolUse
check "a Pre leaves both its marks"               '[ -s "$IDIR/.control-fp" ] && [ -e "$IDIR/.control-armed" ]'
rm -f "$IDIR/.control-fp"
guardcall PostToolUse >/dev/null
check "a vanished fingerprint is tampering"       'control_tampered "$IDIR"'
rm -f "$(control_tamper_file "$IDIR")"
# With no Pre at all — a hook installed mid-session — there is genuinely nothing to compare.
guardcall PostToolUse >/dev/null
check "but no Pre at all is not an accusation"    '! control_tampered "$IDIR"'

echo "===== when the hold ends, its question ends with it ====="
# Preparation records no pause, so `pause_reconcile` never withdrew this one: the card outlived the
# hold and asked whether to wait for a Codex that was already working.
mkcase
codex_decision_ask "$IDIR" preparation exhausted "$(( $(date +%s) + 600 ))" "вікно вичерпано"
STALE="$(jq -r .id "$IDIR/codex-decision.json")"
check "the question stands while the hold does"   'codex_decision_pending "$IDIR"'
check "closing preparation withdraws it"          'codex_decision_close_stage "$IDIR" preparation'
check "and nothing is left to answer"             '! codex_decision_pending "$IDIR"'
answer "$IDIR" "$STALE" claude
check "a late answer to it grants nothing"        '! codex_decision_settle "$IDIR" >/dev/null'
check "and mints no permission"                   '! codex_fallback_choice "$IDIR" >/dev/null'
# A review question is a different question and must not be swept up with it.
codex_decision_ask "$IDIR" review exhausted 0 "вікно вичерпано"
check "closing preparation leaves the review one" '! codex_decision_close_stage "$IDIR" preparation'
check "…still standing"                           'codex_decision_pending "$IDIR"'

echo "===== the night queue waits on the same rule as everything else ====="
# It was carved out of this on the reasoning that holding would leave an empty morning. That is a
# real cost and it was not mine to trade away: an exemption the director did not choose is not his
# default. The predicate is the same one every other entry point uses, so this pins that the queue
# reads it — and that releasing one project does not release the rest.
mkcase; codex_usage 432000
A_IDIR="$IDIR"
mkcase; codex_usage 432000
B_IDIR="$IDIR"
check "a spent window holds the first project"    '[ "$(prep_blocked_reason "$A_IDIR" 1)" = codex ]'
check "and the second one too"                    '[ "$(prep_blocked_reason "$B_IDIR" 1)" = codex ]'
codex_decision_ask "$A_IDIR" preparation exhausted 0 "вікно вичерпано"
answer "$A_IDIR" "$(jq -r .id "$A_IDIR/codex-decision.json")" claude
codex_decision_settle "$A_IDIR" >/dev/null
check "releasing the first releases the first"    '! prep_blocked_reason "$A_IDIR" 1 >/dev/null'
check "…and only the first"                       '[ "$(prep_blocked_reason "$B_IDIR" 1)" = codex ]'
codex_available
check "a window coming back releases the rest"    '! prep_blocked_reason "$B_IDIR" 1 >/dev/null'
check "the queue runner reads that same predicate" 'grep -q "prep_blocked_reason" "$ROOT/bin/queue-runner.sh"'
check "and closes its question when the hold ends" 'grep -q "codex_decision_close_stage" "$ROOT/bin/queue-runner.sh"'

echo "===== a question Codex never answered comes back with him ====="
mkcase
check "nothing is owed to begin with"             '! codex_consultations_owed "$IDIR"'
codex_owe_consultation "$IDIR" 3 "чи тут потрібен воркtree" "вікно вичерпано"
check "the unanswered question is kept"           'codex_consultations_owed "$IDIR"'
check "and it is quoted back verbatim"            'codex_unanswered_consultations "$IDIR" | grep -q worktree || codex_unanswered_consultations "$IDIR" | grep -q "воркtree"'
printf '%s\n' "OTHER-RUN" > "$IDIR/run-id"
check "a question from another run is not owed"   '! codex_consultations_owed "$IDIR"'
printf '%s\n' "$RID" > "$IDIR/run-id"
codex_consultations_settled "$IDIR"
check "answering one clears the queue"            '! codex_consultations_owed "$IDIR"'

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
