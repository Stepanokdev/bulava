#!/bin/bash
# The route a message from the Bulava composer actually takes — executed, not read.
#
# The regression this pins: a chat in Claude+Codex mode said `adaptive_peer` in its environment and
# the worker's first message was still the director's raw text. `worker-send.sh` typed it straight
# into the pane; preflight and composition only ever ran on the night dispatcher's path. The old
# suite passed because its "direct app dispatch" section grepped `prepare-and-inject.sh` for the
# word `preflight` instead of sending anything.
#
# So everything here runs for real: the send script, the queue, the pump, the pipeline, both model
# calls (stubbed binaries that record what they were asked and when), the comparison, composition
# and the hand-over. Claude and Codex are stubs; the orchestration is the engine's own.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

command -v tmux >/dev/null 2>&1 || { echo "⚠️  нема tmux — пропускаю"; exit 0; }

TMP="$(mktemp -d -t chat-pipeline)" || exit 1
KEEP_TMP="${KEEP_TMP:-0}"
SESSION_PID=""
cleanup() {
  [ -n "${SESSION:-}" ] && tmux kill-session -t "$SESSION" 2>/dev/null
  [ "$KEEP_TMP" = 1 ] && { echo "kept: $TMP"; return 0; }
  rm -rf "$TMP"
}
trap cleanup EXIT

# The app bridge must not leak in from the surrounding shell.
#
# Bulava exports the run's chosen model and depth into every process it starts, and sets
# SUPERVISOR_RUN_ENV_FROM_APP=1 to say "trust what I exported" — which is exactly what
# `worker-send.sh` honours by NOT reading the run-env file. So when this suite runs from inside a
# Bulava chat, as it does whenever an agent runs it, the section below writes a run-env naming one
# model and the engine is then quite correctly called with the chat's own. The assertion measured
# the environment instead of the product, and reported the failure as if the engine had ignored
# the director's choice.
#
# The same shape already cost this repository months on test-checkpoint-nested.sh. The test owns
# these four values; whatever the surrounding session thinks they are is none of its business.
unset SUPERVISOR_RUN_ENV_FROM_APP \
      SUPERVISOR_CLAUDE_MODEL SUPERVISOR_CLAUDE_EFFORT \
      SUPERVISOR_CODEX_MODEL SUPERVISOR_CODEX_EFFORT

export HOME="$TMP/home"; mkdir -p "$HOME/.claude/sessions"
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
export SUPERVISOR_DESIGN_RESEARCH=0
# Most scenarios below drive the peer stages through a SECOND message of an open task, because that
# is the cheapest way to get a second envelope. Since a follow-up no longer gets peer positions by
# default (the worker consults Codex itself), the mechanics are exercised with the switch on; the
# default is asserted once, in the end-to-end scenario near the bottom.
export SUPERVISOR_FOLLOWUP_PEERS=1
export SUPERVISOR_PLAN_TIMEOUT=60
export SUPERVISOR_TURN_PROBE_GAP=0
export SUPERVISOR_PUMP_POLL=1
export SUPERVISOR_PUMP_GRACE=1
export SUPERVISOR_WATCHDOG_POLL=1
# A stubbed engine "thinks" for a second. Long enough that two of them plainly overlap and that a
# withdrawal has something to interrupt, short enough that the whole route can be walked fourteen
# times inside a verifier's window.
export STUB_SLEEP=1
# The sections that deliberately take the PLAIN route end at `inject_task`, which waits for a real
# Claude prompt to appear in the pane. This pane is a sink and never shows one, so each of those
# sends sat out the full ninety-second wait — three of them, five minutes of the suite, spent
# proving nothing. What those sections assert is that no engine was called, and that is true the
# moment the send returns.
export SUPERVISOR_PROMPT_WAIT=2
export SUPERVISOR_INJECT_CALM=0
export SUPERVISOR_INJECT_TYPE_TRIES=1
export SUPERVISOR_ENTER_CONFIRM_WAIT=1
REC="$TMP/rec"; mkdir -p "$REC"
export REC

PROJ="$TMP/project"; mkdir -p "$PROJ"
git -C "$PROJ" init -q 2>/dev/null
: > "$PROJ/README.md"; git -C "$PROJ" add -A 2>/dev/null; git -C "$PROJ" -c user.email=t@t -c user.name=t commit -qm init 2>/dev/null

. "$BIN/supervisor-lib.sh"
# What "the window is spent" means, in today's terms. It used to be written into these fixtures
# as 99%, back when the guard paused at 90; the guard is 100 now — quota is bought to be used —
# and 99% is an engine that is still working. Taking the number from the guard keeps every
# assertion below about what it was written to be about, under any configuration.
SPENT="${SUPERVISOR_USAGE_GUARD:-100}"

SLUG="$(slug_for "$PROJ")"
IDIR="$(instance_dir "$SLUG")"
SESSION="$(session_name "$SLUG")"
mkdir -p "$IDIR"
printf '%s\n' "$(canon_path "$PROJ")" > "$IDIR/project"
printf '%s\n' "$SESSION" > "$IDIR/session"
printf '%s\n' "RUN-CHAT-1" > "$IDIR/run-id"
printf '%s\n' "sid-chat-1" > "$IDIR/claude-session-id"
printf '%s\n' "main" > "$IDIR/branch"
: > "$IDIR/started-at"
: > "$IDIR/direct-chat"
ln -sf "$BIN/consult-codex.sh" "$IDIR/consult-codex"
ln -sf "$BIN/add-check.sh" "$IDIR/add-check"
ln -sf "$BIN/worker-outcome.sh" "$IDIR/report-outcome"

# A pane that exists and never says a turn is running; the CLI's own status file is what
# `_turn_running` believes, so idleness here is stated rather than screen-scraped.
tmux new-session -d -s "$SESSION" 'while :; do sleep 1; done' 2>/dev/null
tmux has-session -t "$SESSION" 2>/dev/null || { echo "⚠️  tmux не піднявся — пропускаю"; exit 0; }
sleep 0.3
tmux capture-pane -pt "$SESSION" >/dev/null 2>&1
SESSION_PID=$$
cat > "$HOME/.claude/sessions/worker.json" <<JSON
{"pid":$SESSION_PID,"sessionId":"sid-chat-1","tmux":"$SESSION:@1.%1","status":"idle"}
JSON

# ---------------------------------------------------------------------------- the stubbed engines
mkdir -p "$TMP/stub"
cat > "$TMP/stub/claude" <<'STUB'
#!/bin/bash
prompt=""; for a in "$@"; do prompt="$a"; done
n="$(ls "$REC" 2>/dev/null | grep -c '^claude-.*\.prompt$')"
case "$n" in ''|*[!0-9]*) n=0 ;; esac
n=$((n + 1))
printf '%s' "$prompt" > "$REC/claude-$n.prompt"
s="$(perl -MTime::HiRes -e 'printf "%.0f", Time::HiRes::time()*1000')"
printf '%s' "$$" > "$REC/claude.pid"
: > "$REC/claude.started"
sleep "${STUB_SLEEP:-2}"
: > "$REC/claude.ended"
e="$(perl -MTime::HiRes -e 'printf "%.0f", Time::HiRes::time()*1000')"
printf '%s %s\n' "$s" "$e" >> "$REC/claude.timing"
printf '%s\n' "$*" > "$REC/claude-$n.argv"
[ "${STUB_CLAUDE_FAIL:-0}" = 1 ] && exit 1
# One role failing, not every Claude call: context and the other roles go on as they would.
[ -n "${STUB_CLAUDE_FAIL_ON:-}" ] && case "$prompt" in *"$STUB_CLAUDE_FAIL_ON"*) exit 1 ;; esac
cat <<'BRIEF'
REAL GOAL — CLAUDE-BRIEF-SENTINEL finish the rename
APPROACH — one file
MISSED REQUIREMENTS AND EDGE CASES — none material
REPOSITORY EVIDENCE — README.md
PROOF — grep
BRIEF
STUB
cat > "$TMP/stub/codex" <<'STUB'
#!/bin/bash
# Not a turn. The engine asks the real CLI this before spending a call, and a stub that
# treated it as a brief would record "login status" as the run's prompt and depth.
if [ "${1:-}" = login ]; then echo "Logged in using ChatGPT"; exit 0; fi
out=""; prev=""; prompt=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prompt="$a"; prev="$a"
done
# The triage choosing steps answers JSON, and only for the steps it was asked about.
case "$prompt" in *"THE STEPS TO DECIDE ABOUT"*)
  printf '%s' "$prompt" > "$REC/codex-pick.prompt"
  [ -n "$out" ] && printf '%s\n' "${STUB_PICK_JSON:-}" > "$out"; exit 0 ;; esac
kind=brief
case "$prompt" in *"INDEPENDENT POSITION"*|*"separate preparation roles"*) kind=align ;; esac
n="$(ls "$REC" 2>/dev/null | grep -c "^codex-$kind-.*\.prompt$")"
case "$n" in ''|*[!0-9]*) n=0 ;; esac
n=$((n + 1))
printf '%s' "$prompt" > "$REC/codex-$kind-$n.prompt"
printf '%s\n' "$*" > "$REC/codex-$kind-$n.argv"
s="$(perl -MTime::HiRes -e 'printf "%.0f", Time::HiRes::time()*1000')"
printf '%s' "$$" > "$REC/codex-$kind.pid"
: > "$REC/codex-$kind.started"
sleep "${STUB_SLEEP:-2}"
: > "$REC/codex-$kind.ended"
e="$(perl -MTime::HiRes -e 'printf "%.0f", Time::HiRes::time()*1000')"
printf '%s %s\n' "$s" "$e" >> "$REC/codex-$kind.timing"
if [ "$kind" = align ]; then
  [ "${STUB_ALIGN_FAIL:-0}" = 1 ] && exit 1
  answer='AGREED CORE — ALIGNMENT-SENTINEL rename the file
MATERIAL DELTAS — none
DECISIONS CLAUDE MUST MAKE — none
ACCEPTANCE CHECKS — grep finds the new name
OPTIONAL — none'
else
  [ "${STUB_CODEX_FAIL:-0}" = 1 ] && exit 1
  answer='REAL GOAL — CODEX-BRIEF-SENTINEL rename
APPROACH — sed
MISSED REQUIREMENTS AND EDGE CASES — trailing newline
REPOSITORY EVIDENCE — README.md
PROOF — grep'
fi
[ -n "$out" ] && printf '%s\n' "$answer" > "$out"
printf '%s\n' "$answer"
STUB
cat > "$TMP/stub/inject" <<'STUB'
#!/bin/bash
# A stand-in for inject_task, and it publishes the same ladder — anything that carries a message to
# the worker has to, or a withdrawal arriving mid-handoff has nothing to read.
say() {
  printf '%s\n' "$1" > "$INJECT_PHASE_FILE"
  printf '%s %s\n' "$(date '+%F %T.000')" "$1" >> "$INJECT_PHASE_FILE.log"
}
[ -e "$REC/inject-fail" ] && { say waiting; exit 1; }
say waiting; say typing; say typed; say submitting
printf '%s\n' "$(perl -MTime::HiRes -e 'printf "%.0f", Time::HiRes::time()*1000')" >> "$REC/inject.timing"
cat "$2" >> "$REC/injected.txt"
printf '\n===INJECT-BOUNDARY===\n' >> "$REC/injected.txt"
say submitted; say confirmed
exit 0
STUB
chmod +x "$TMP/stub/claude" "$TMP/stub/codex" "$TMP/stub/inject"
export SUPERVISOR_INJECT_CMD="$TMP/stub/inject"
export PATH="$TMP/stub:$PATH"

send() {   # $1=message  $2=message-id  $3=pipeline
  bash "$BIN/worker-send.sh" --mode conversation --message-id "$2" --pipeline "${3:-adaptive-peer}" \
    "$PROJ" "sid-chat-1" "-" "RUN-CHAT-1" "$1" 2>&1
}
wait_quiet() {  # wait for the pump to finish, up to $1 seconds
  local i=0 max=$(( ${1:-60} * 4 ))
  while [ "$i" -lt "$max" ]; do
    if [ "$(pending_count "$IDIR")" = 0 ] && ! pipeline_running "$IDIR" \
       && [ ! -d "$IDIR/pump.lock" ]; then return 0; fi
    sleep 0.25; i=$((i + 1))
  done
  return 1
}
ms_of() { awk '{print $1}' "$1" 2>/dev/null | head -1; }
ms_end() { awk '{print $2}' "$1" 2>/dev/null | head -1; }

echo "===== a message from the composer is prepared before the worker sees anything ====="
out="$(STUB_SLEEP=2 send "Виправ опечатку у README" "11111111-1111-1111-1111-111111111111")"
rc=$?
case "$out" in *"TIER=preparing"*) ok "worker-send answers 'preparing', not 'delivered'" ;;
  *) bad "worker-send did not enter the prepared route: $out" ;; esac
[ "$rc" = 5 ] && ok "and exits 5 so the app can show the honest state" || bad "exit code was $rc, expected 5"
wait_quiet 90 || bad "the pump never finished"

for f in peer-claude.md peer-codex.md peer-alignment.md; do
  found="$(find "$IDIR/messages" -name "$f" 2>/dev/null | head -1)"
  [ -s "$found" ] && ok "$f was produced for this message" || bad "$f missing"
done

echo "===== both positions were formed from the SAME task and neither saw the other ====="
cp="$(cat "$REC/claude-1.prompt" 2>/dev/null)"
xp="$(cat "$REC/codex-brief-1.prompt" 2>/dev/null)"
case "$cp" in *"Виправ опечатку у README"*) ok "Claude was given the original task" ;; *) bad "Claude's prompt lost the task" ;; esac
case "$xp" in *"Виправ опечатку у README"*) ok "Codex was given the original task" ;; *) bad "Codex's prompt lost the task" ;; esac
[ -n "$cp" ] && [ "$cp" = "$xp" ] && ok "byte-identical prompts — the same question, asked twice" \
  || bad "the two positions were asked different questions"
case "$cp" in *CODEX-BRIEF-SENTINEL*) bad "Claude could see Codex's position" ;; *) ok "Claude never saw Codex's position" ;; esac
case "$xp" in *CLAUDE-BRIEF-SENTINEL*) bad "Codex could see Claude's position" ;; *) ok "Codex never saw Claude's position" ;; esac

echo "===== they ran side by side, and the comparison waited for both ====="
cs="$(ms_of "$REC/claude.timing")"; ce="$(ms_end "$REC/claude.timing")"
xs="$(ms_of "$REC/codex-brief.timing")"; xe="$(ms_end "$REC/codex-brief.timing")"
as="$(ms_of "$REC/codex-align.timing")"
if [ -n "$cs" ] && [ -n "$xs" ] && [ "$cs" -lt "$xe" ] && [ "$xs" -lt "$ce" ]; then
  ok "the two intervals overlap (claude ${cs}..${ce}, codex ${xs}..${xe})"
else
  bad "the positions were formed one after the other (claude ${cs}..${ce}, codex ${xs}..${xe})"
fi
if [ -n "$as" ] && [ "$as" -ge "$ce" ] && [ "$as" -ge "$xe" ]; then
  ok "the comparison started only after both had finished"
else
  bad "the comparison started at $as, before a position was finished (claude ends $ce, codex ends $xe)"
fi
ap="$(cat "$REC/codex-align-1.prompt" 2>/dev/null)"
case "$ap" in *CLAUDE-BRIEF-SENTINEL*) ok "the comparison received Claude's position" ;; *) bad "the comparison had no Claude position" ;; esac
case "$ap" in *CODEX-BRIEF-SENTINEL*) ok "and Codex's" ;; *) bad "the comparison had no Codex position" ;; esac

echo "===== nothing reached the worker until the comparison was done ====="
it="$(head -1 "$REC/inject.timing" 2>/dev/null)"
ae="$(ms_end "$REC/codex-align.timing")"
[ -n "$it" ] && [ -n "$ae" ] && [ "$it" -ge "$ae" ] \
  && ok "the hand-over ($it) came after the comparison ended ($ae)" \
  || bad "the worker was given something at $it, comparison ended $ae"
[ "$(grep -c '===INJECT-BOUNDARY===' "$REC/injected.txt" 2>/dev/null)" = 1 ] \
  && ok "exactly one hand-over for one message" \
  || bad "the worker was addressed $(grep -c '===INJECT-BOUNDARY===' "$REC/injected.txt" 2>/dev/null) time(s)"

echo "===== what the worker was actually handed ====="
inj="$(cat "$REC/injected.txt")"
case "$inj" in *"[СПІЛЬНЕ ОСМИСЛЕННЯ]"*) ok "the prompt carries the shared-reasoning section" ;; *) bad "no [СПІЛЬНЕ ОСМИСЛЕННЯ] in the prompt" ;; esac
for f in peer-claude.md peer-codex.md peer-alignment.md; do
  case "$inj" in *"$f"*) ok "it names $f" ;; *) bad "it does not name $f" ;; esac
done
case "$inj" in *"consult-codex"*) ok "it names the consultation channel" ;; *) bad "consult-codex is not offered" ;; esac
case "$inj" in *"Числового ліміту консультацій НЕМАЄ"*) ok "with no numeric cap" ;; *) bad "consultations look capped" ;; esac
case "$inj" in *"Виправ опечатку у README"*) ok "and the director's own words" ;; *) bad "the original message was lost" ;; esac
case "$inj" in *"$IDIR/messages/"*) ok "the peer paths are this message's own, not the instance's shared copies" ;;
  *) bad "the prompt points at shared artifacts" ;; esac

echo "===== the worker's own tools know what the task was ====="
jq -e --arg t "Виправ опечатку у README" '.task == $t' "$IDIR/dispatch.json" >/dev/null 2>&1 \
  && ok "dispatch.json carries the chat message (consult-codex and the review gate read it)" \
  || bad "the chat left no dispatch record: $(cat "$IDIR/dispatch.json" 2>/dev/null)"

echo "===== two messages sent one after the other, without waiting for the first ====="
#
# Back to back on purpose: the night dispatcher's rule is that a newer task supersedes the one
# still thinking, and applying that rule to a conversation would silently throw away something the
# director said. Both arrive, in the order they were typed, each with its own reasoning.
rm -f "$REC/inject.timing"; : > "$REC/injected.txt"
send "Прибери зайвий пробіл" "22222222-2222-2222-2222-222222222222" >/dev/null
out_b="$(send "І ще крапку з комою" "2b2b2b2b-2b2b-2b2b-2b2b-2b2b2b2b2b2b")"
case "$out_b" in *"TIER=preparing"*) ok "the second send is accepted while the first is still being prepared" ;;
  *) bad "the second send was refused: $out_b" ;; esac
[ "$(pending_count "$IDIR")" -ge 1 ] && ok "both are queued, not merged" || bad "the queue lost one of them"
wait_quiet 180 || bad "the pump never finished both messages"
inj2="$(cat "$REC/injected.txt")"
case "$inj2" in *"Прибери зайвий пробіл"*) ok "the first of the pair was delivered" ;; *) bad "the first of the pair never arrived" ;; esac
case "$inj2" in *"І ще крапку з комою"*) ok "and so was the second" ;; *) bad "the second was dropped — a conversation is not a dispatch queue" ;; esac
first_at="$(grep -n 'Прибери зайвий пробіл' "$REC/injected.txt" | head -1 | cut -d: -f1)"
second_at="$(grep -n 'І ще крапку з комою' "$REC/injected.txt" | head -1 | cut -d: -f1)"
[ -n "$first_at" ] && [ -n "$second_at" ] && [ "$first_at" -lt "$second_at" ] \
  && ok "in the order they were typed" || bad "they arrived out of order"
case "$inj2" in *"Виправ опечатку"*) bad "a delivery repeated an older message" ;; *) ok "and neither repeated an older one" ;; esac
d1="$(find "$IDIR/messages" -maxdepth 1 -type d -name '*-11111111*' | head -1)"
d2="$(find "$IDIR/messages" -maxdepth 1 -type d -name '*-22222222*' | head -1)"
d2b="$(find "$IDIR/messages" -maxdepth 1 -type d -name '*-2b2b2b2b*' | head -1)"
[ -n "$d2" ] && [ -n "$d2b" ] && [ "$d2" != "$d2b" ] \
  && ok "each message kept its own artifacts" || bad "the two messages shared an artifact directory"
case "$inj2" in *"$d2b"*) ok "the second prompt points at the second message's briefs" ;; *) bad "the second prompt points elsewhere" ;; esac
second_block="$(awk '/І ще крапку з комою/,0' "$REC/injected.txt")"
case "$second_block" in *"$d2"*) bad "the second prompt still points at the FIRST message's briefs" ;; *) ok "and never at the first's" ;; esac

echo "===== a message taken back mid-preparation STOPS the work, not just the delivery ====="
#
# The envelope of the message being prepared is still in the queue and looks exactly like one that
# is merely waiting. Answering from the queue alone made the withdrawal look right — nothing was
# injected — while both engines kept running, the project stayed held and the conversation sat on
# "preparing" until the stage finished on its own.
: > "$REC/injected.txt"; rm -f "$REC/inject.timing" "$REC"/*.started "$REC"/*.ended "$REC"/*.pid
STUB_SLEEP=12 send "Перейменуй змінну" "33333333-3333-3333-3333-333333333333" >/dev/null
tries=0; while ! pipeline_running "$IDIR" && [ "$tries" -lt 60 ]; do sleep 0.5; tries=$((tries + 1)); done
if ! pipeline_running "$IDIR"; then
  bad "preparation never became observable, so the withdrawal could not be tested"
else
  tries=0; while [ ! -e "$REC/claude.started" ] && [ "$tries" -lt 60 ]; do sleep 0.5; tries=$((tries + 1)); done
  [ -e "$REC/claude.started" ] && ok "both engines are genuinely running" || bad "no engine had started"
  verdict="$(bash "$BIN/worker-withdraw.sh" "$PROJ" "33333333-3333-3333-3333-333333333333")"
  [ "$verdict" = withdrawn ] && ok "the engine calls it withdrawn, not 'already read'" \
    || bad "withdrawing a message under preparation said: $verdict"

  # Within a beat, not within the 45 seconds the stubs were told to think for.
  tries=0; while pipeline_running "$IDIR" && [ "$tries" -lt 20 ]; do sleep 0.5; tries=$((tries + 1)); done
  pipeline_running "$IDIR" && bad "the run still reads as preparing — the app would hold the project" \
    || ok "the run stops reading as preparing at once"
  # Decisive, and it has to be: both stubs were told to think for twelve seconds, so "it has not
  # finished yet" is true whether the withdrawal killed them or left them running. Their own pids
  # are the difference.
  gone() { local pid; pid="$(cat "$1" 2>/dev/null)"; [ -n "$pid" ] || return 0; ! kill -0 "$pid" 2>/dev/null; }
  tries=0
  while { ! gone "$REC/claude.pid" || ! gone "$REC/codex-brief.pid"; } && [ "$tries" -lt 20 ]; do
    sleep 0.5; tries=$((tries + 1))
  done
  gone "$REC/claude.pid" && ok "the Claude call was actually terminated" \
    || bad "Claude is still running a brief nobody is waiting for"
  gone "$REC/codex-brief.pid" && ok "and so was the Codex call" \
    || bad "Codex is still running a brief nobody is waiting for"
  [ -e "$REC/claude.ended" ] && bad "the Claude brief ran to completion after being withdrawn" \
    || ok "neither brief ran to completion"
  [ "$(pending_count "$IDIR")" = 0 ] && ok "its envelope is gone, so nothing re-prepares it" \
    || bad "the withdrawn message is still queued for preparation"

  wait_quiet 120 || bad "the pump did not settle after the withdrawal"
  case "$(cat "$REC/injected.txt")" in *"Перейменуй змінну"*) bad "the withdrawn message reached the worker anyway" ;;
    *) ok "and nothing was handed over" ;; esac
fi
rm -rf "$IDIR/cancelled" 2>/dev/null
rm -f "$REC"/*.started "$REC"/*.ended "$REC"/*.pid 2>/dev/null

echo "===== one engine down degrades, two engines down still delivers ====="
: > "$REC/injected.txt"; rm -rf "$REC"/*.timing "$REC"/codex-*.prompt "$REC"/claude-*.prompt
STUB_CODEX_FAIL=1 send "Прибери крапку" "44444444-4444-4444-4444-444444444444" >/dev/null
wait_quiet 90 || bad "the pump never finished the Codex-down message"
d4="$(find "$IDIR/messages" -maxdepth 1 -type d -name '*-44444444*' | head -1)"
[ -s "$d4/peer-claude.md" ] && ok "Claude's position survived Codex going down" || bad "the Claude position was lost too"
[ -s "$d4/peer-codex.md" ] && bad "a failed Codex call left a position behind" || ok "no half-written Codex position"
[ -s "$d4/peer-alignment.md" ] && bad "a comparison was invented from one position" || ok "no comparison was invented from one position"
grep -q 'peer/codex: FAILED' "$SUPERVISOR_STATE_DIR/supervisor.log" && ok "the failure is named in the log" || bad "the log does not say Codex failed"
grep -q 'DEGRADED — no Codex position' "$SUPERVISOR_STATE_DIR/supervisor.log" && ok "and so is the degradation" || bad "the degradation is not recorded"
case "$(cat "$REC/injected.txt")" in *"peer-claude.md"*) ok "the worker still got the surviving position" ;; *) bad "the surviving position never reached the worker" ;; esac

: > "$REC/injected.txt"
STUB_CLAUDE_FAIL=1 STUB_CODEX_FAIL=1 send "Прибери кому" "55555555-5555-5555-5555-555555555555" >/dev/null
wait_quiet 90 || bad "the pump never finished the both-down message"
inj5="$(cat "$REC/injected.txt")"
case "$inj5" in *"Прибери кому"*) ok "with both engines down the original message still arrives" ;; *) bad "the message was lost when both engines failed" ;; esac
case "$inj5" in *"[СПІЛЬНЕ ОСМИСЛЕННЯ]"*) bad "a shared-reasoning section was offered with nothing behind it" ;; *) ok "and it does not pretend to carry positions" ;; esac
grep -q 'neither position available' "$SUPERVISOR_STATE_DIR/supervisor.log" && ok "the log says the worker got the original task" || bad "the total degradation is not recorded"

echo "===== a stale preflight cannot be handed to a new message ====="
d5="$(find "$IDIR/messages" -maxdepth 1 -type d -name '*-55555555*' | head -1)"
case "$inj5" in *"$d1"*|*"$d2"*|*"$d4"*) bad "the empty message reached for an older message's artifacts" ;;
  *) ok "nothing older leaked in" ;; esac
[ -n "$d5" ] && ok "it had its own (empty) artifact directory" || bad "no artifact directory for the fifth message"

echo "===== Claude-only never calls Codex ====="
: > "$REC/injected.txt"; rm -f "$REC"/codex-*.prompt "$REC"/claude-*.prompt
send "Просто відповідай" "66666666-6666-6666-6666-666666666666" plain >/dev/null
sleep 1
ls "$REC"/codex-*.prompt >/dev/null 2>&1 && bad "the plain pipeline called Codex" || ok "the plain pipeline called no Codex"
ls "$REC"/claude-*.prompt >/dev/null 2>&1 && bad "the plain pipeline ran a Claude brief" || ok "and formed no brief"

echo "===== the engine's own switches can still turn preparation off ====="
: > "$REC/injected.txt"
out="$(SUPERVISOR_PREFLIGHT_ENABLE=0 send "Ще одна дрібниця" "77777777-7777-7777-7777-777777777777")"
case "$out" in *"TIER=preparing"*) bad "SUPERVISOR_PREFLIGHT_ENABLE=0 still prepared" ;; *) ok "SUPERVISOR_PREFLIGHT_ENABLE=0 falls back to the plain route" ;; esac
out="$(SUPERVISOR_COLLABORATION_MODE=legacy send "І ще одна" "88888888-8888-8888-8888-888888888888")"
case "$out" in *"TIER=preparing"*) bad "legacy collaboration mode still prepared" ;; *) ok "legacy collaboration mode falls back too" ;; esac

echo "===== the run's chosen model and depth are what the engines were called with ====="
: > "$REC/injected.txt"; rm -f "$REC"/codex-*.argv "$REC"/claude-*.argv
cat > "$IDIR/run-env" <<'ENVF'
export SUPERVISOR_CLAUDE_EFFORT='xhigh'
export SUPERVISOR_CLAUDE_MODEL='claude-opus-5'
export SUPERVISOR_CODEX_EFFORT='low'
export SUPERVISOR_CODEX_MODEL='gpt-5-codex'
export SUPERVISOR_COLLABORATION_MODE='adaptive_peer'
ENVF
send "Заміни слово" "99999999-9999-9999-9999-999999999999" >/dev/null
wait_quiet 90 || bad "the pump never finished the model-choice message"
ca="$(cat "$REC/claude-1.argv" 2>/dev/null)"
xa="$(cat "$REC/codex-brief-1.argv" 2>/dev/null)"
case "$ca" in *"--effort xhigh"*) ok "Claude was called at the chosen depth" ;; *) bad "Claude's depth was not the run's: $ca" ;; esac
case "$ca" in *"--model claude-opus-5"*) ok "and the chosen model" ;; *) bad "Claude's model was not the run's: $ca" ;; esac
case "$xa" in *"model_reasoning_effort=low"*) ok "Codex was called at the chosen depth" ;; *) bad "Codex's depth was not the run's: $xa" ;; esac
case "$xa" in *"-m gpt-5-codex"*) ok "and the chosen model" ;; *) bad "Codex's model was not the run's: $xa" ;; esac
rm -f "$IDIR/run-env"

echo "===== a message sent while the worker is mid-turn waits, and nothing is researched yet ====="
#
# Research against a tree the previous turn is still editing would be research about a different
# repository — and the old path did worse than that: it typed the raw message in.
: > "$REC/injected.txt"; rm -f "$REC"/claude-*.prompt "$REC"/codex-*.prompt
cat > "$HOME/.claude/sessions/worker.json" <<JSON
{"pid":$SESSION_PID,"sessionId":"sid-chat-1","tmux":"$SESSION:@1.%1","status":"busy"}
JSON
send "Поки зайнятий" "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" >/dev/null
sleep 4
[ "$(pending_count "$IDIR")" = 1 ] && ok "the message waits in the queue" || bad "the queued message vanished"
ls "$REC"/claude-*.prompt >/dev/null 2>&1 && bad "a position was formed while the worker was mid-turn" \
  || ok "no position was formed while the worker was mid-turn"
[ -s "$REC/injected.txt" ] && bad "something was handed over during a running turn" || ok "and nothing was handed over"
cat > "$HOME/.claude/sessions/worker.json" <<JSON
{"pid":$SESSION_PID,"sessionId":"sid-chat-1","tmux":"$SESSION:@1.%1","status":"idle"}
JSON
wait_quiet 90 || bad "the pump never picked the message up once the worker went idle"
case "$(cat "$REC/injected.txt")" in *"Поки зайнятий"*) ok "once the worker is free it is prepared and delivered" ;;
  *) bad "the waiting message never arrived" ;; esac
ls "$REC"/claude-*.prompt >/dev/null 2>&1 && ok "and only then were the positions formed" || bad "no positions were formed at all"

echo "===== resuming an older conversation prepares against the run the resume created ====="
#
# The session is really gone here — killed, as it is after the machine sleeps or the app is quit —
# and the launcher that revives it is stubbed so the suite can watch what happens AFTER. A resumed
# chat gets a NEW run id, so an envelope stamped before the resume would be thrown away as
# belonging to a run that no longer exists.
: > "$REC/injected.txt"; rm -f "$REC"/claude-*.prompt "$REC"/codex-*.prompt
tmux kill-session -t "$SESSION" 2>/dev/null
cat > "$TMP/stub/night-shift" <<STUB
#!/bin/bash
# resume <proj> <sid> <branch> --no-attach
[ "\$1" = resume ] || exit 1
tmux new-session -d -s "$SESSION" 'while :; do sleep 1; done' 2>/dev/null
printf '%s\n' "RUN-RESUMED" > "$IDIR/run-id"
printf '%s\n' "resumed-sid" > "$IDIR/claude-session-id"
exit 0
STUB
chmod +x "$TMP/stub/night-shift"
out_r="$(SUPERVISOR_NIGHT_SHIFT_CMD="$TMP/stub/night-shift" \
  bash "$BIN/worker-send.sh" --mode conversation --message-id "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" \
    --pipeline adaptive-peer "$PROJ" "sid-chat-1" "main" "RUN-CHAT-1" "після відновлення" 2>&1)"
case "$out_r" in *"TIER=preparing"*) ok "a resumed conversation is prepared, not injected raw" ;;
  *) bad "the resumed send did not take the prepared route: $out_r" ;; esac
envf="$(pending_head "$IDIR" || true)"
if [ -n "$envf" ]; then
  jq -e '.run_id == "RUN-RESUMED"' "$envf" >/dev/null 2>&1 \
    && ok "its envelope names the run the resume created" \
    || bad "the envelope carries '$(jq -r '.run_id // "—"' "$envf" 2>/dev/null)' instead of RUN-RESUMED"
  jq -e '.pipeline == "adaptive-peer" and .intent == "conversation"' "$envf" >/dev/null 2>&1 \
    && ok "and which pipeline it was accepted for" || bad "the envelope does not name its pipeline"
else
  bad "nothing was queued after the resume"
fi
cat > "$HOME/.claude/sessions/worker.json" <<JSON
{"pid":$SESSION_PID,"sessionId":"resumed-sid","tmux":"$SESSION:@1.%1","status":"idle"}
JSON
wait_quiet 120 || bad "the pump never finished the resumed message"
case "$(cat "$REC/injected.txt")" in *"після відновлення"*) ok "and the prepared prompt reached the revived session" ;;
  *) bad "the resumed message never arrived" ;; esac
case "$(cat "$REC/injected.txt")" in *"[СПІЛЬНЕ ОСМИСЛЕННЯ]"*) ok "with both positions, like any other message" ;;
  *) bad "the resumed message arrived unprepared" ;; esac
printf '%s\n' "RUN-CHAT-1" > "$IDIR/run-id"
printf '%s\n' "sid-chat-1" > "$IDIR/claude-session-id"
cat > "$HOME/.claude/sessions/worker.json" <<JSON
{"pid":$SESSION_PID,"sessionId":"sid-chat-1","tmux":"$SESSION:@1.%1","status":"idle"}
JSON

echo "===== a message for somebody else's run is refused, and changes nothing ====="
#
# The composer's choices used to be written down before the run-id was checked, so a chat that was
# about to be told "another run owns this project" could still change that run's model and depth on
# its way out.
cat > "$IDIR/run-env" <<'ENVF'
export SUPERVISOR_CLAUDE_EFFORT='high'
export SUPERVISOR_CLAUDE_MODEL='sonnet'
export SUPERVISOR_CODEX_EFFORT='medium'
export SUPERVISOR_COLLABORATION_MODE='adaptive_peer'
ENVF
before="$(cat "$IDIR/run-env")"
queued_before="$(pending_count "$IDIR")"
out_c="$(SUPERVISOR_RUN_ENV_FROM_APP=1 SUPERVISOR_CLAUDE_EFFORT=max SUPERVISOR_CLAUDE_MODEL=opus \
  SUPERVISOR_CODEX_EFFORT=xhigh SUPERVISOR_COLLABORATION_MODE=adaptive_peer \
  bash "$BIN/worker-send.sh" --mode conversation --message-id "dddddddd-dddd-dddd-dddd-dddddddddddd" \
    --pipeline adaptive-peer "$PROJ" "sid-chat-1" "main" "SOMEBODY-ELSES-RUN" "не моє" 2>&1)"
rc_c=$?
case "$out_c" in *"TIER=conflict"*) ok "a stale run id is refused" ;; *) bad "a stale run id was accepted: $out_c" ;; esac
[ "$(cat "$IDIR/run-env")" = "$before" ] \
  && ok "and the other run's model and depth are untouched" \
  || bad "the refused message rewrote another run's configuration: $(grep CLAUDE_MODEL "$IDIR/run-env")"
[ "$(pending_count "$IDIR")" = "$queued_before" ] && ok "and nothing was queued" || bad "a refused message was queued anyway"
rm -f "$IDIR/run-env"

echo "===== changing the model mid-conversation reaches the engines, not just the composer ====="
#
# The run already had choices on disk. Loading them before saving the app's — which is what this
# did — overwrote the new choice with the old one and then wrote the old one back, so the composer
# could say Opus while every preflight, consultation and review went on running the previous run's
# settings for ever.
cat > "$IDIR/run-env" <<'ENVF'
export SUPERVISOR_CLAUDE_EFFORT='low'
export SUPERVISOR_CLAUDE_MODEL='haiku'
export SUPERVISOR_CODEX_EFFORT='low'
export SUPERVISOR_CODEX_MODEL='gpt-5-codex-mini'
export SUPERVISOR_COLLABORATION_MODE='adaptive_peer'
ENVF
: > "$REC/injected.txt"; rm -f "$REC"/claude-*.argv "$REC"/codex-*.argv "$REC"/claude-*.prompt "$REC"/codex-*.prompt
SUPERVISOR_RUN_ENV_FROM_APP=1 \
SUPERVISOR_CLAUDE_EFFORT=max SUPERVISOR_CLAUDE_MODEL=opus \
SUPERVISOR_CODEX_EFFORT=xhigh SUPERVISOR_CODEX_MODEL=gpt-5-codex \
SUPERVISOR_COLLABORATION_MODE=adaptive_peer \
  bash "$BIN/worker-send.sh" --mode conversation --message-id "cccccccc-cccc-cccc-cccc-cccccccccccc" \
    --pipeline adaptive-peer "$PROJ" "sid-chat-1" "-" "RUN-CHAT-1" "Після зміни моделі" >/dev/null 2>&1
wait_quiet 120 || bad "the pump never finished the model-change message"
na="$(cat "$REC/claude-1.argv" 2>/dev/null)"
nx="$(cat "$REC/codex-brief-1.argv" 2>/dev/null)"
case "$na" in *"--effort max"*) ok "Claude ran at the depth the composer now shows" ;; *) bad "Claude still ran at the old depth: $na" ;; esac
case "$na" in *"--model opus"*) ok "and on the model it now shows" ;; *) bad "Claude still ran on the old model: $na" ;; esac
case "$nx" in *"model_reasoning_effort=xhigh"*) ok "Codex too" ;; *) bad "Codex still ran at the old depth: $nx" ;; esac
case "$nx" in *"-m gpt-5-codex"*) ok "and on the model it now shows" ;; *) bad "Codex still ran on the old model: $nx" ;; esac
grep -q "SUPERVISOR_CLAUDE_MODEL='opus'" "$IDIR/run-env" \
  && ok "the run's file was updated rather than re-written with its own old values" \
  || bad "run-env still holds the previous choice: $(grep CLAUDE_MODEL "$IDIR/run-env")"

echo "===== Stop between accepting a message and starting to prepare it ====="
#
# The app says "preparing" from the moment the envelope exists, and the pump is started detached,
# so there is a real window where the director can press Stop on a message no pipeline has claimed
# yet. Cancelling only a LIVE pipeline left the envelope in the queue and the pump delivered it a
# moment later — Stop that did nothing, on a message the app said it was stopping.
cat > "$TMP/stub/pump-noop" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$TMP/stub/pump-noop"
: > "$REC/injected.txt"; rm -f "$REC"/claude-*.prompt "$REC"/codex-*.prompt
SUPERVISOR_PUMP_CMD="$TMP/stub/pump-noop" \
  bash "$BIN/worker-send.sh" --mode conversation --message-id "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee" \
    --pipeline adaptive-peer "$PROJ" "sid-chat-1" "main" "RUN-CHAT-1" "зупини мене" >/dev/null 2>&1
[ "$(pending_count "$IDIR")" = 1 ] && ok "the message is accepted and waiting, with no pipeline yet" \
  || bad "the message was not queued"
pipeline_running "$IDIR" && bad "a pipeline is already running — the gap could not be tested" \
  || ok "and nothing has claimed it"
bash "$BIN/worker-interrupt.sh" "$PROJ" "RUN-CHAT-1" >/dev/null 2>&1
rc_i=$?
[ "$rc_i" = 0 ] && ok "Stop reports that it stopped something" || bad "Stop said there was nothing to stop (rc=$rc_i)"
[ "$(pending_count "$IDIR")" = 0 ] && ok "the waiting message is gone from the queue" \
  || bad "Stop left the message queued — the pump will deliver it"
# And a real pump started afterwards must not resurrect it.
nohup bash "$BIN/message-pump.sh" "$SLUG" >/dev/null 2>&1 &
wait_quiet 60 || bad "the pump did not settle"
case "$(cat "$REC/injected.txt")" in *"зупини мене"*) bad "the stopped message was delivered anyway" ;;
  *) ok "and a pump started afterwards does not resurrect it" ;; esac
ls "$REC"/claude-*.prompt >/dev/null 2>&1 && bad "a position was formed for a stopped message" \
  || ok "no engine was ever asked about it"
rm -rf "$IDIR/cancelled" 2>/dev/null

echo "===== taking a message back while it is being handed over ====="
#
# Injection is not a moment: it waits for a prompt, pastes, presses Enter. A withdrawal arriving
# inside that used to be answered "withdrawn" while the text was already sitting in the composer —
# and that text would then ride along with whatever the director typed next. The handoff publishes
# where it has got to, and the answer differs on the two sides of the Enter key.
#
# The injector below is the barrier: it stops at a named phase and waits to be released, so the
# withdrawal can be made to arrive at exactly the instant under test.
cat > "$TMP/stub/inject-barrier" <<'EOF'
#!/bin/bash
# $1=session $2=composed file. Walks the SAME ladder inject_task walks, in the same order and at
# the same moments — each phase is published as that step becomes true, never before it.
say() {
  printf '%s\n' "$1" > "$INJECT_PHASE_FILE"
  printf '%s %s\n' "$(date '+%F %T.000')" "$1" >> "$INJECT_PHASE_FILE.log"
}
hold() { local i=0; while [ ! -e "$BARRIER_RELEASE" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i+1)); done; }
say waiting
: > "$BARRIER_AT_WAITING"
[ "${BARRIER_PHASE:-}" = waiting ] && hold
say typing
: > "$BARRIER_AT_TYPING"
[ "${BARRIER_PHASE:-}" = typing ] && hold
say typed
: > "$BARRIER_AT_TYPED"
[ "${BARRIER_PHASE:-}" = typed ] && hold
say submitting
: > "$BARRIER_AT_SUBMITTING"
[ "${BARRIER_PHASE:-}" = submitting ] && hold
cat "$2" >> "$REC/injected.txt"
printf '\n===INJECT-BOUNDARY===\n' >> "$REC/injected.txt"
say submitted
: > "$BARRIER_AT_SUBMITTED"
[ "${BARRIER_PHASE:-}" = submitted ] && hold
say confirmed
exit 0
EOF
chmod +x "$TMP/stub/inject-barrier"
export BARRIER_AT_WAITING="$TMP/at-waiting" BARRIER_AT_TYPING="$TMP/at-typing" BARRIER_AT_TYPED="$TMP/at-typed" BARRIER_AT_SUBMITTING="$TMP/at-submitting" BARRIER_AT_SUBMITTED="$TMP/at-submitted" BARRIER_RELEASE="$TMP/release"

# A pump outlives the message it was started for — it drains the queue and only then exits — so it
# carries the environment it was born with. Harmless in production, where everything that matters
# is re-read per message from the run's own file, but this seam is chosen per send, so the barrier
# runs wait for the previous pump to be genuinely gone first.
no_pump() { local i=0; while pgrep -f "message-pump.sh $SLUG" >/dev/null 2>&1 && [ "$i" -lt 200 ]; do sleep 0.2; i=$((i+1)); done; }

barrier_run() {   # $1=phase to stop at  $2=message id  $3=text
  no_pump
  rm -f "$BARRIER_AT_WAITING" "$BARRIER_AT_TYPING" "$BARRIER_AT_TYPED" "$BARRIER_AT_SUBMITTING" "$BARRIER_AT_SUBMITTED" "$BARRIER_RELEASE"
  : > "$REC/injected.txt"
  SUPERVISOR_INJECT_CMD="$TMP/stub/inject-barrier" BARRIER_PHASE="$1" send "$3" "$2" >/dev/null
}
wait_for() {  # $1=file $2=seconds
  local i=0; while [ ! -e "$1" ] && [ "$i" -lt $(( ${2:-30} * 4 )) ]; do sleep 0.25; i=$((i+1)); done
  [ -e "$1" ]
}

barrier_run typed "f1f1f1f1-f1f1-f1f1-f1f1-f1f1f1f1f1f1" "текст уже в композері"
if wait_for "$BARRIER_AT_TYPED" 60; then
  ok "the handoff reaches the composer and holds there"
  v="$(bash "$BIN/worker-withdraw.sh" "$PROJ" "f1f1f1f1-f1f1-f1f1-f1f1-f1f1f1f1f1f1")"
  [ "$v" = withdrawn ] && ok "typed but not submitted is still a real withdrawal" \
    || bad "a message that was only typed came back as '$v'"
  : > "$BARRIER_RELEASE"
  wait_quiet 120 || bad "the pump did not settle after the typed-phase withdrawal"
  case "$(cat "$REC/injected.txt")" in *"текст уже в композері"*) bad "the withdrawn text was handed over anyway" ;;
    *) ok "and nothing was handed over" ;; esac
  # The queue legitimately holds earlier plain-route sends this suite made; what must not be in it
  # is THIS message, or the watchdog would deliver a withdrawn message minutes later.
  grep -q "текст уже в композері" "$(undelivered_file "$IDIR")" 2>/dev/null \
    && bad "the withdrawn message was parked for a later retry" \
    || ok "nor parked to arrive later"
else
  bad "the handoff never reached the typed phase"
fi

barrier_run typing "f0f0f0f0-f0f0-f0f0-f0f0-f0f0f0f0f0f0" "текст ще вставляється"
if wait_for "$BARRIER_AT_TYPING" 60; then
  ok "the handoff can be caught mid-paste"
  v="$(bash "$BIN/worker-withdraw.sh" "$PROJ" "f0f0f0f0-f0f0-f0f0-f0f0-f0f0f0f0f0f0")"
  [ "$v" = withdrawn ] && ok "a half-pasted message is still a real withdrawal" \
    || bad "a message caught mid-paste came back as '$v'"
  grep -q 'was in the composer (typing) and has been cleared' "$SUPERVISOR_STATE_DIR/supervisor.log" \
    && ok "and the composer it had already started changing was cleared" \
    || bad "nothing cleared the composer a half-paste had changed"
  : > "$BARRIER_RELEASE"
  wait_quiet 120 || bad "the pump did not settle after the mid-paste withdrawal"
  case "$(cat "$REC/injected.txt")" in *"текст ще вставляється"*) bad "the half-pasted message was submitted anyway" ;;
    *) ok "and it was never submitted" ;; esac
else
  bad "the handoff never reached the typing phase"
fi

barrier_run submitting "f4f4f4f4-f4f4-f4f4-f4f4-f4f4f4f4f4f4" "Enter уже йде"
if wait_for "$BARRIER_AT_SUBMITTING" 60; then
  ok "the handoff can be caught with the Enter key going in"
  v="$(bash "$BIN/worker-withdraw.sh" "$PROJ" "f4f4f4f4-f4f4-f4f4-f4f4-f4f4f4f4f4f4")"
  [ "$v" = already-read ] && ok "which is already too late to call it withdrawn" \
    || bad "a message with Enter in flight came back as '$v'"
  : > "$BARRIER_RELEASE"
  wait_quiet 120 || bad "the pump did not settle after the submitting-phase withdrawal"
else
  bad "the handoff never reached the submitting phase"
fi

barrier_run submitted "f2f2f2f2-f2f2-f2f2-f2f2-f2f2f2f2f2f2" "це вже надіслано"
if wait_for "$BARRIER_AT_SUBMITTED" 60; then
  ok "the handoff reaches the submitted phase"
  v="$(bash "$BIN/worker-withdraw.sh" "$PROJ" "f2f2f2f2-f2f2-f2f2-f2f2-f2f2f2f2f2f2")"
  [ "$v" = already-read ] && ok "past the Enter key the answer is 'already read', not 'withdrawn'" \
    || bad "a submitted message came back as '$v' — the app would hide something Claude has"
  : > "$BARRIER_RELEASE"
  wait_quiet 120 || bad "the pump did not settle after the submitted-phase withdrawal"
  case "$(cat "$REC/injected.txt")" in *"це вже надіслано"*) ok "and the message did arrive, as the answer said" ;;
    *) bad "the answer said 'already read' but nothing arrived" ;; esac
else
  bad "the handoff never reached the submitted phase"
fi

rm -f "$BARRIER_RELEASE"; unset BARRIER_PHASE
no_pump
: > "$REC/injected.txt"
send "після бар'єрів" "f3f3f3f3-f3f3-f3f3-f3f3-f3f3f3f3f3f3" >/dev/null
wait_quiet 120 || bad "the pump did not recover after the barrier runs"
v="$(bash "$BIN/worker-withdraw.sh" "$PROJ" "f3f3f3f3-f3f3-f3f3-f3f3-f3f3f3f3f3f3")"
[ "$v" = already-read ] && ok "a message the worker already has cannot be taken back later either" \
  || bad "a delivered message came back as '$v'"

echo "===== asking twice for one press of the button gives one answer ====="
#
# Stopping what is running and taking the message back are two paths in the app that both end at
# this one engine call. The first took the message back; the second found nothing left and reported
# it read — so the app marked a message the worker had never seen as read, and hid it.
no_pump
: > "$REC/injected.txt"
SUPERVISOR_PUMP_CMD="$TMP/stub/pump-noop" \
  bash "$BIN/worker-send.sh" --mode conversation --message-id "a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1" \
    --pipeline adaptive-peer "$PROJ" "sid-chat-1" "main" "RUN-CHAT-1" "двічі забрати" >/dev/null 2>&1
first="$(bash "$BIN/worker-withdraw.sh" "$PROJ" "a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1")"
second="$(bash "$BIN/worker-withdraw.sh" "$PROJ" "a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1")"
third="$(bash "$BIN/worker-withdraw.sh" "$PROJ" "a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1")"
[ "$first" = withdrawn ] && ok "the first answer is 'withdrawn'" || bad "the first answer was '$first'"
{ [ "$second" = "$first" ] && [ "$third" = "$first" ]; } \
  && ok "and every later ask gets the same answer, not 'already read'" \
  || bad "asking again changed the answer to '$second'/'$third'"
[ "$(bash "$BIN/worker-withdraw.sh" "$PROJ" "f3f3f3f3-f3f3-f3f3-f3f3-f3f3f3f3f3f3")" = already-read ] \
  && ok "a delivered message answers 'already read' every time too" || bad "the delivered verdict drifted"

echo "===== the handoff leaves its own record beside the message ====="
#
# `stages.jsonl` says the delivery stage took six seconds; this says what happened inside them and
# when — including for a handoff that was taken back, which is exactly when somebody needs it.
d3="$(find "$IDIR/messages" -maxdepth 1 -type d -name '*-f3f3f3f3*' | head -1)"
if [ -n "$d3" ] && [ -s "$d3/handoff.log" ]; then
  ok "the delivered message kept its handoff trail"
  seq3="$(awk '{print $3}' "$d3/handoff.log" | grep -v '^outcome' | tr '\n' ' ' | sed 's/ *$//')"
  case "$seq3" in
    "waiting typing typed submitting submitted confirmed") ok "with the full sequence, in order" ;;
    *) bad "the trail reads '$seq3'" ;;
  esac
  grep -q 'outcome=delivered' "$d3/handoff.log" && ok "and how it ended" || bad "the trail does not say how it ended"
else
  bad "a delivered message left no handoff trail in its artifacts"
fi
d0="$(find "$IDIR/messages" -maxdepth 1 -type d -name '*-f0f0f0f0*' | head -1)"
if [ -n "$d0" ] && [ -s "$d0/handoff.log" ]; then
  ok "and so did the one taken back mid-paste"
  grep -q ' typing' "$d0/handoff.log" && ok "showing how far it had got" || bad "the withdrawn trail has no phases"
  grep -q 'outcome=withdrawn' "$d0/handoff.log" && ok "and that it was withdrawn" \
    || bad "the withdrawn trail does not say so"
else
  bad "the withdrawn handoff left no trail"
fi

echo "===== a night dispatch and a chat message never prepare at the same time ====="
#
# They used to hold two different locks, which is the same as no lock: both wrote the run's
# active-stage marker, the chat's dispatch record replaced the one the dispatcher was guarding
# against, and the dispatcher then abandoned its own work as superseded.
: > "$REC/injected.txt"; rm -f "$REC"/claude-*.prompt "$REC"/codex-*.prompt
DISPATCH_ID="D-CONCURRENT-1"
jq -nc --arg id "$DISPATCH_ID" --arg task "нічна задача" '{id:$id, at:"2026-01-01T00:00:00Z", task:$task, report_key:"dcon"}' \
  > "$IDIR/dispatch.json"
TASKFILE="$IDIR/.dispatch-inject-$DISPATCH_ID.txt"
printf '%s\n' "нічна задача" > "$TASKFILE"
( SUPERVISOR_INJECT_CMD="$TMP/stub/inject" bash "$BIN/prepare-and-inject.sh" "$BIN" "$PROJ" "$SESSION" \
    "$SUPERVISOR_STATE_DIR" "$TASKFILE" "$IDIR" "$DISPATCH_ID" >/dev/null 2>&1 ) &
dispatch_pid=$!
sleep 2
out_x="$(send "чат під час нічної задачі" "c0c0c0c0-c0c0-c0c0-c0c0-c0c0c0c0c0c0")"
case "$out_x" in *"TIER=preparing"*) ok "the chat message is accepted while a dispatch is preparing" ;;
  *) bad "the chat send was refused during a dispatch: $out_x" ;; esac
wait "$dispatch_pid" 2>/dev/null
wait_quiet 180 || bad "the pump never finished after the concurrent dispatch"

inj_c="$(cat "$REC/injected.txt")"
case "$inj_c" in *"нічна задача"*) ok "the dispatch was delivered, not abandoned as superseded" ;;
  *) bad "the night dispatch was lost when a chat message arrived" ;; esac
case "$inj_c" in *"чат під час нічної задачі"*) ok "and so was the chat message" ;;
  *) bad "the chat message was lost" ;; esac
d_at="$(grep -n 'нічна задача' "$REC/injected.txt" | head -1 | cut -d: -f1)"
c_at="$(grep -n 'чат під час нічної задачі' "$REC/injected.txt" | head -1 | cut -d: -f1)"
[ -n "$d_at" ] && [ -n "$c_at" ] && [ "$d_at" -lt "$c_at" ] \
  && ok "in that order — the one that started first finished first" \
  || bad "the two deliveries interleaved"

# Their stage intervals must not overlap: one run at a time, whoever asked.
python3 - "$IDIR" "$DISPATCH_ID" <<'PYEOF' && ok "their preparations never overlapped" || bad "two preparations ran at the same time"
import json, os, sys, glob
idir, did = sys.argv[1], sys.argv[2]
runs = []
for f in glob.glob(os.path.join(idir, "messages", "*", "stages.jsonl")):
    rows = [json.loads(l) for l in open(f) if l.strip()]
    if not rows: continue
    runs.append((os.path.basename(os.path.dirname(f)),
                 min(r["started_ms"] for r in rows), max(r["ended_ms"] for r in rows)))
runs.sort(key=lambda r: r[1])
recent = runs[-2:]
if len(recent) < 2:
    print("not enough runs to compare", file=sys.stderr); sys.exit(1)
(a_n, a_s, a_e), (b_n, b_s, b_e) = recent
print("  %s: %s..%s" % (a_n, a_s, a_e), file=sys.stderr)
print("  %s: %s..%s" % (b_n, b_s, b_e), file=sys.stderr)
sys.exit(0 if b_s >= a_e else 1)
PYEOF

echo "===== the final Codex review still runs on a chat the pipeline delivered ====="
#
# The chat route now leaves a dispatch record where it never left one before, and the review gate
# reads that file. This runs the real gate — the same Stop hook a finished turn triggers — against
# the instance this suite has been talking to.
: > "$PROJ/slug.txt"; ( cd "$PROJ" && git add -A && git -c user.email=t@t -c user.name=t commit -qm "worker change" >/dev/null 2>&1 )
echo "a real change" >> "$PROJ/slug.txt"
printf '%s\n' "$(git -C "$PROJ" rev-parse HEAD)" > "$IDIR/base-sha"
( cd "$PROJ" && git add -A && git -c user.email=t@t -c user.name=t commit -qm "worker change 2" >/dev/null 2>&1 )
cat > "$TMP/stub/codex-review" <<'EOF'
#!/bin/bash
if echo "$*" | grep -q "HANDOFF | BLOCKED"; then
  : > "$REVIEW_CALLED"
  echo "STATE: COMPLETE"
  echo "VERDICT: PASS"
else
  echo "VERDICT: PASS"
fi
EOF
mkdir -p "$TMP/gatestub" && cp "$TMP/stub/codex-review" "$TMP/gatestub/codex" && chmod +x "$TMP/gatestub/codex"
REVIEW_CALLED="$TMP/review-called"; rm -f "$REVIEW_CALLED" "$IDIR/done"
TRANS="$TMP/transcript.jsonl"
printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"text","text":"готово"}]}}' > "$TRANS"
printf '{"session_id":"sid-chat-1","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$TRANS" "$PROJ" \
  | REVIEW_CALLED="$REVIEW_CALLED" ORCHESTRATOR_RUN_ID="RUN-CHAT-1" SUPERVISOR_VERIFIER_ENABLED=0 \
    PATH="$TMP/gatestub:$PATH" bash "$BIN/../hooks/review-gate.sh" >/dev/null 2>&1
[ -e "$REVIEW_CALLED" ] && ok "the gate asked Codex to review the work" || bad "the review gate never ran the reviewer"
[ "$(cat "$IDIR/done" 2>/dev/null)" = passed ] && ok "and recorded its verdict" \
  || bad "the gate left no verdict: $(cat "$IDIR/done" 2>/dev/null || echo none)"
[ -s "$IDIR/dispatches/$(jq -r '.id' "$IDIR/dispatch.json").done" ] \
  && ok "against the dispatch record the chat route wrote" \
  || bad "the verdict was not tied to the chat's dispatch"
rm -f "$IDIR/done"

echo "===== a consultation knows the task, and runs at the run's chosen depth ====="
cat > "$IDIR/run-env" <<'ENVF'
export SUPERVISOR_CODEX_EFFORT='xhigh'
export SUPERVISOR_CODEX_MODEL='gpt-5-codex'
export SUPERVISOR_COLLABORATION_MODE='adaptive_peer'
ENVF
rm -f "$REC"/codex-*.argv "$REC"/codex-*.prompt
cat > "$TMP/stub/usage" <<'EOF'
#!/bin/bash
mkdir -p "$SUPERVISOR_STATE_DIR"
echo '{"five_hour":{"used_percentage":1,"resets_at":0},"seven_day":{"used_percentage":1}}' > "$SUPERVISOR_STATE_DIR/codex-usage.json"
EOF
chmod +x "$TMP/stub/usage"
( cd "$PROJ" && ORCHESTRATOR_RUN_ID=RUN-CHAT-1 SUPERVISOR_CODEX_USAGE_CMD="$TMP/stub/usage" \
    bash "$BIN/consult-codex.sh" "чи достатньо одного проходу" ) >/dev/null 2>&1
cq="$(cat "$REC/codex-brief-1.prompt" 2>/dev/null)"
# Whatever the last delivered message was — the point is that a chat leaves a dispatch record at
# all. It never did, so `consult-codex` asked Codex about an empty task.
last_task="$(jq -r '.task // ""' "$IDIR/dispatch.json" 2>/dev/null)"
[ -n "$last_task" ] && case "$cq" in *"$last_task"*) true ;; *) false ;; esac \
  && ok "Codex was told what the task is (it used to be blank in a chat)" \
  || bad "the consultation carried no task (dispatch said: ${last_task:-<nothing>})"
ca2="$(cat "$REC/codex-brief-1.argv" 2>/dev/null)"
case "$ca2" in *"model_reasoning_effort=xhigh"*) ok "and ran at the run's chosen depth" ;; *) bad "the consultation used a default depth: $ca2" ;; esac
rec="$(find "$IDIR/consultations/RUN-CHAT-1" -name metrics.json 2>/dev/null | head -1)"
[ -n "$rec" ] && jq -e '.codex_effort == "xhigh"' "$rec" >/dev/null 2>&1 \
  && ok "the record says which depth answered" || bad "the consultation record does not name the depth"
rm -f "$IDIR/run-env"

echo "===== a big task, then 'commit it and release' — end to end through the real pump ====="
# The whole complaint in one run: the second message must not buy the first message's ceremony.
rm -rf "$IDIR/thread" "$IDIR/messages" "$IDIR/pending" "$REC"/codex-*.prompt "$REC"/codex-*.argv \
       "$REC"/claude-*.prompt "$REC/injected.txt" "$IDIR/done" "$IDIR/outcome.json"
rm -f "$IDIR/run-env"
export SUPERVISOR_CODEX_USAGE_CMD="/usr/bin/true" SUPERVISOR_CLAUDE_USAGE_CMD="/usr/bin/true"

out="$(STUB_SLEEP=0 send "Спроектуй з нуля новий екран історії прогонів і адаптуй його під iPad" \
        "22222222-2222-2222-2222-222222222221")"
case "$out" in *"TIER=preparing"*) ok "the opening message is prepared" ;; *) bad "opening message: $out" ;; esac
wait_quiet 120 || bad "the pump never finished the opening message"
first_art="$(find "$IDIR/messages" -name task.txt 2>/dev/null | head -1)"
first_art="$(dirname "$first_art" 2>/dev/null)"
[ "$(tr -d '[:space:]' < "$first_art/.relation" 2>/dev/null)" = new ] \
  && ok "and opens a task" || bad "the opening message was not treated as a new task"

codex_calls_before="$(ls "$REC" 2>/dev/null | grep -c '^codex-brief-.*\.prompt$')"
started="$(date +%s)"
# The default, not the switch the rest of this suite runs with: a follow-up gets no peer positions.
export SUPERVISOR_FOLLOWUP_PEERS=0
out="$(STUB_SLEEP=0 send "закоміть, померджай і випусти версію" \
        "22222222-2222-2222-2222-222222222222")"
case "$out" in *"TIER=preparing"*) ok "the follow-up is accepted the same way" ;; *) bad "follow-up: $out" ;; esac
wait_quiet 120 || bad "the pump never finished the follow-up"
elapsed=$(( $(date +%s) - started ))

follow_art=""
for d in "$IDIR/messages"/*/; do
  [ "$(tr -d '[:space:]' < "$d/.relation" 2>/dev/null)" = continue ] && follow_art="$d"
done
[ -n "$follow_art" ] \
  && ok "the follow-up is recognised as the next step of the open task" \
  || bad "the follow-up was prepared as a brand new task, exactly as before"
[ "$(tr -d '[:space:]' < "$follow_art/.scale" 2>/dev/null)" = followup ] \
  && ok "so it skips classification, research and design precedent" \
  || bad "the follow-up paid for the full opening stage again"
if [ -s "$follow_art/peer-claude.md" ] || [ -s "$follow_art/peer-codex.md" ] || [ -s "$follow_art/peer-alignment.md" ]; then
  bad "the follow-up still bought two independent positions and a comparison"
else
  ok "and nobody formed a position on it — the worker already has the context"
fi
codex_calls_after="$(ls "$REC" 2>/dev/null | grep -c '^codex-brief-.*\.prompt$')"
[ "${codex_calls_after:-0}" = "${codex_calls_before:-0}" ] \
  && ok "no Codex call was spent on the follow-up before the worker saw it" \
  || bad "Codex was called $((codex_calls_after - codex_calls_before)) time(s) to prepare a one-line follow-up"
grep -q "skipped.*follow-up" "$SUPERVISOR_STATE_DIR/supervisor.log" 2>/dev/null \
  && ok "and the log says the stages were skipped, and why" || bad "the skip left no trace in the log"
grep -q "ПРОДОВЖЕННЯ" "$follow_art/composed.txt" 2>/dev/null \
  && ok "the worker is told plainly that this continues the task" \
  || bad "the worker was handed the follow-up as if the task were starting"
grep -q "СПІЛЬНЕ ОСМИСЛЕННЯ" "$follow_art/composed.txt" 2>/dev/null \
  && bad "the prompt still points at peer files that were never written" \
  || ok "the prompt does not point at positions that do not exist"
grep -q "КОНСУЛЬТАЦІЇ З CODEX" "$follow_art/composed.txt" 2>/dev/null \
  && ok "and still hands the worker the consultation channel — Codex on demand" \
  || bad "the worker was not told how to call Codex itself"
export SUPERVISOR_FOLLOWUP_PEERS=1
grep -q "закоміть, померджай" "$REC/injected.txt" 2>/dev/null \
  && ok "and it actually reached the worker" || bad "the follow-up never arrived"
[ "$elapsed" -lt 90 ] && ok "the whole follow-up took ${elapsed}s" \
  || bad "a one-line follow-up still took ${elapsed}s"

echo "===== a message parked behind a limit is not called 'both engines are reading it' ====="
rm -f "$IDIR/queue-wait.json"
jq -n --arg spent "$SPENT" --argjson ts "$(date +%s)" \
  '{ts:$ts, observed_at:$ts, source:"cli",
    five_hour:{used_percentage:($spent|tonumber), resets_at:($ts + 3600), window_minutes:300},
    seven_day:{used_percentage:5, resets_at:($ts + 500000), window_minutes:10080}}' \
  > "$SUPERVISOR_STATE_DIR/usage.json"
pause_record "$IDIR" claude "$(( $(date +%s) + 3600 ))" "usage guard"
out="$(STUB_SLEEP=0 send "ще одна правка" "22222222-2222-2222-2222-222222222223")"
tries=0
while [ ! -s "$IDIR/queue-wait.json" ] && [ "$tries" -lt 60 ]; do sleep 0.25; tries=$((tries + 1)); done
[ "$(jq -r '.reason // ""' "$IDIR/queue-wait.json" 2>/dev/null)" = limit ] \
  && ok "the queue says what it is really waiting for" \
  || bad "the app has nothing to show but 'preparing': $(cat "$IDIR/queue-wait.json" 2>/dev/null)"
[ -z "$(find "$IDIR/messages" -newer "$IDIR/queue-wait.json" -name 'peer-*.md' 2>/dev/null)" ] \
  && ok "and no engine was started for it" || bad "a position was formed while the worker was parked"
drop_pending "$IDIR" "22222222-2222-2222-2222-222222222223" >/dev/null 2>&1
rm -f "$(pause_file "$IDIR")" "$(pause_last_file "$IDIR")" "$SUPERVISOR_STATE_DIR/usage.json"
pkill -f "message-pump.sh $SLUG" 2>/dev/null || true

echo "===== the app is quit while a message waits, and the watchdog opens it after ====="
# Quitting Bulava kills the pump and nothing else. Nobody is left to open the envelope, and the
# only thing that will ever notice is the watchdog — so this drives the real one, with the real
# pump behind it, and asks whether the director's message actually arrives.
rm -rf "$IDIR/thread" "$IDIR/pending" "$REC/injected.txt"
rm -f "$IDIR/done" "$IDIR/outcome.json" "$IDIR/queue-wait.json"
out="$(STUB_SLEEP=0 send "перейменуй поле у README" "33333333-3333-3333-3333-333333333331")"
case "$out" in *"TIER=preparing"*) ok "the message is accepted" ;; *) bad "send said: $out" ;; esac
# The quit: kill the pump before it can take the envelope, and clear what a dead process leaves.
pkill -f "message-pump.sh $SLUG" 2>/dev/null || true
sleep 0.5
rm -rf "$IDIR/pump.lock" "$IDIR/pipeline.lock"
rm -f "$(pipeline_active_file "$IDIR")"
[ "$(pending_count "$IDIR")" != 0 ] \
  && ok "…and its envelope is still in the queue with nobody to open it" \
  || ok "the pump had already taken it — the restart is still exercised below"

SUPERVISOR_WATCHDOG_POLL=1 SUPERVISOR_IDLE_KILL_SECS=0 SUPERVISOR_STALL_PARK_SECS=0 \
  bash "$BIN/watchdog.sh" "$SLUG" >/dev/null 2>&1 &
WDPID=$!
tries=0
while [ "$tries" -lt 240 ]; do
  grep -q "перейменуй поле у README" "$REC/injected.txt" 2>/dev/null && break
  sleep 0.5; tries=$((tries + 1))
done
kill "$WDPID" 2>/dev/null; wait "$WDPID" 2>/dev/null
grep -q "перейменуй поле у README" "$REC/injected.txt" 2>/dev/null \
  && ok "the watchdog started a new pump and the message reached the worker" \
  || bad "a message accepted before the app closed never arrived"
first_art=""
for d in "$IDIR/messages"/*/; do
  grep -q "перейменуй поле у README" "$d/task.txt" 2>/dev/null && first_art="$d"
done
[ -n "$first_art" ] && [ -s "$first_art/peer-claude.md" ] && [ -s "$first_art/peer-codex.md" ] \
  && ok "…prepared properly, with both positions, rather than typed in raw" \
  || bad "the revived pump delivered something unprepared"
pkill -f "message-pump.sh $SLUG" 2>/dev/null || true

echo "===== a message the worker would not take is queued, and the log does not call it delivered ====="
: > "$REC/inject-fail"
send "постав крапку в кінці README" "99999999-9999-9999-9999-999999999999" >/dev/null
wait_quiet 90 || bad "the pump never finished"
rm -f "$REC/inject-fail"
pkill -f "message-pump.sh $SLUG" 2>/dev/null || true
jq -e 'select(.id == "99999999-9999-9999-9999-999999999999")' "$(undelivered_file "$IDIR")" >/dev/null 2>&1 \
  && ok "the prepared message went into the retry queue" || bad "the refused message was not queued"
pseq="$(grep -o 'message [0-9]* prepared, but the worker did not take it' "$SUPERVISOR_STATE_DIR/supervisor.log" | tail -1 | awk '{print $2}')"
[ -n "$pseq" ] && ok "the log says it was queued, not delivered" || bad "the log does not say the message was queued"
# Sequence numbers repeat across pumps, so it is the LAST word about this one that must not say it.
last="$(grep "message $pseq " "$SUPERVISOR_STATE_DIR/supervisor.log" | grep -v 'preparing message' | tail -1)"
[ -n "$pseq" ] && case "$last" in *"message $pseq delivered"*) false ;; *) true ;; esac \
  && ok "and never claims it was delivered" || bad "the log claims a queued message was delivered: $last"


echo "===== a pipeline of roles, through the chat: phases in order, test cases reach the worker and the review ====="
pkill -f "message-pump.sh $SLUG" 2>/dev/null || true
RP="$SUPERVISOR_STATE_DIR/pipelines/roles-chat"; mkdir -p "$RP"
cat > "$RP/pipeline.json" <<'JSON'
{"schema":"bulava.pipeline/1","id":"roles-chat","name":"Ролі","description":"тест","revision":1,
 "nodes":[
  {"id":"chat","module":"bulava/trigger.chat@1"},
  {"id":"context","module":"bulava/prep.context@1"},
  {"id":"triage","module":"bulava/prep.classify@1","title":"Тріаж"},
  {"id":"ba","module":"bulava/prep.position@1","title":"Бізнес-аналітик","params":{"engine":"codex","required":true},"prompt":"BA-ROLE: {{TASK}}"},
  {"id":"qa","module":"bulava/prep.position@1","title":"Тестувальник","params":{"engine":"claude","required":true},"prompt":"QA-ROLE: {{TASK}}"},
  {"id":"arch-claude","module":"bulava/prep.position@1","title":"Архітектор Claude","params":{"engine":"claude","required":true},"prompt":"ARCH-ROLE: {{TASK}}"},
  {"id":"arch-codex","module":"bulava/prep.position@1","title":"Архітектор Codex","params":{"engine":"codex","required":true},"prompt":"ARCH-ROLE: {{TASK}}"},
  {"id":"agree","module":"bulava/prep.align@1","title":"Домовленість","params":{"required":true}},
  {"id":"compose","module":"bulava/prep.compose@1"},
  {"id":"deliver","module":"bulava/agent.claude@1"},
  {"id":"review","module":"bulava/gate.review@1"},
  {"id":"merge","module":"bulava/out.merge@1"}],
 "edges":[
  {"from":"chat.task","to":"context.task"},{"from":"chat.task","to":"triage.task"},
  {"from":"context.context","to":"ba.context"},{"from":"triage.context","to":"ba.context"},
  {"from":"context.context","to":"qa.context"},{"from":"triage.context","to":"qa.context"},
  {"from":"ba.position","to":"arch-claude.context"},{"from":"qa.position","to":"arch-claude.context"},
  {"from":"ba.position","to":"arch-codex.context"},{"from":"qa.position","to":"arch-codex.context"},
  {"from":"arch-claude.position","to":"agree.positions"},{"from":"arch-codex.position","to":"agree.positions"},
  {"from":"agree.checks","to":"compose.in"},{"from":"compose.brief","to":"deliver.brief"},
  {"from":"deliver.work","to":"review.work"},{"from":"review.pass","to":"merge.work"},{"from":"review.fail","to":"deliver.feedback","loop":{"max":3}}]}
JSON
rm -rf "$REC"/*; : > "$REC/injected.txt"
out="$(STUB_SLEEP=1 send "ROLE-TASK додай поле email" "77777777-7777-7777-7777-777777777771" roles-chat)"
case "$out" in *"TIER=preparing"*) ok "the role pipeline is taken for this chat message" ;; *) bad "send said: $out" ;; esac
wait_quiet 120 || bad "the pump never finished the role pipeline"
# Which prompt went where, by the role prompt's own sentinel.
when() { for f in "$REC"/$1-*.prompt; do grep -q "$2" "$f" 2>/dev/null && { echo "$f"; return; }; done; }
ba_p="$(when codex-brief BA-ROLE)"; qa_p="$(when claude QA-ROLE)"
[ -n "$ba_p" ] && ok "the analyst ran on Codex with its own prompt" || bad "no Codex call carried the analyst's prompt"
[ -n "$qa_p" ] && ok "the tester ran on Claude with its own prompt" || bad "no Claude call carried the tester's prompt"
arch_cl="$(when claude ARCH-ROLE)"; arch_cx="$(when codex-brief ARCH-ROLE)"
[ -n "$arch_cl" ] && [ -n "$arch_cx" ] && ok "both architects ran, one on each engine" || bad "architects: claude=$arch_cl codex=$arch_cx"
[ -n "$arch_cl" ] && grep -q "CODEX-BRIEF-SENTINEL" "$arch_cl" && grep -q "CLAUDE-BRIEF-SENTINEL" "$arch_cl" \
  && ok "an architect was given what the analyst and the tester concluded" || bad "the architect did not read phase one"
ap="$(ls "$REC"/codex-align-*.prompt 2>/dev/null | head -1)"
[ -n "$ap" ] && [ "$(grep -o 'SENTINEL' "$ap" | wc -l | tr -d ' ')" -ge 4 ] \
  && ok "the agreement read all four roles" || bad "the agreement prompt: $(head -c 300 "$ap" 2>/dev/null)"
# Phases in time: every role of phase two starts after phase one has ended; the worker after the agreement.
p1_end="$(cat "$REC/claude.timing" "$REC/codex-brief.timing" 2>/dev/null | awk '{print $2}' | sort -n | head -2 | tail -1)"
p2_start="$(cat "$REC/claude.timing" "$REC/codex-brief.timing" 2>/dev/null | awk '{print $1}' | sort -n | tail -2 | head -1)"
[ -n "$p1_end" ] && [ -n "$p2_start" ] && [ "$p2_start" -ge "$p1_end" ] \
  && ok "the architects started only after the analyst and the tester had finished" || bad "phases overlap: phase 1 ended $p1_end, phase 2 started $p2_start"
it="$(head -1 "$REC/inject.timing" 2>/dev/null)"; ae="$(ms_end "$REC/codex-align.timing")"
[ -n "$it" ] && [ -n "$ae" ] && [ "$it" -ge "$ae" ] && ok "the worker got the task only after the agreement" || bad "hand-over $it, agreement ended $ae"
inj="$(cat "$REC/injected.txt")"
case "$inj" in *"ROLE-TASK додай поле email"*) ok "the worker got his words" ;; *) bad "the worker never got the task" ;; esac
case "$inj" in *"[РОЛІ ПІДГОТОВКИ]"*"Тестувальник"*"Тест-кейси з узгодженого рішення — це критерії готовності"*) ok "with the roles and the test cases as the bar for done" ;;
  *) bad "the worker's prompt has no roles / test cases section" ;; esac
plan_found=""; for d in "$IDIR/messages"/*/; do grep -q "ROLE-TASK" "$d/task.txt" 2>/dev/null && plan_found="$d/plan.md"; done
[ -n "$plan_found" ] && grep -q "ALIGNMENT-SENTINEL" "$plan_found" \
  && grep -q "ALIGNMENT-SENTINEL" "$IDIR/plan.md" 2>/dev/null \
  && ok "the agreement is the plan the review is held to" || bad "plan.md for this message: $(head -c 200 "$plan_found" 2>/dev/null)"
pkill -f "message-pump.sh $SLUG" 2>/dev/null || true

for failing in "STUB_CLAUDE_FAIL_ON=QA-ROLE tester" "STUB_ALIGN_FAIL=1 agreement"; do
  setting="${failing%% *}"; who="${failing#* }"; var="${setting%%=*}"
  echo "===== a required role fails ($who): the worker receives nothing, his words are kept ====="
  rm -rf "$REC"/* "$IDIR/held"; : > "$REC/injected.txt"
  mid="77777777-7777-7777-7777-77777777777$([ "$who" = tester ] && echo 2 || echo 3)"
  pkill -f "message-pump.sh $SLUG" 2>/dev/null || true; no_pump
  export "$setting"; STUB_SLEEP=0 send "HELD-TASK $who" "$mid" roles-chat >/dev/null
  wait_quiet 120 || bad "the pump never finished"
  unset "$var"
  pkill -f "message-pump.sh $SLUG" 2>/dev/null || true
  [ ! -s "$REC/injected.txt" ] && [ ! -s "$REC/inject.timing" ] && ok "nothing was handed to the worker" || bad "the worker was given: $(head -c 300 "$REC/injected.txt")"
  ! jq -e --arg id "$mid" 'select(.id == $id)' "$(undelivered_file "$IDIR")" >/dev/null 2>&1 \
    && ok "and nothing waits in the retry queue for the watchdog to type in" || bad "the message sits in the retry queue — it would arrive unprepared"
  grep -q "ALIGNMENT-SENTINEL" "$IDIR/plan.md" 2>/dev/null && ! grep -q "Ролі не дійшли згоди" "$IDIR/degraded.md" 2>/dev/null \
    && ok "the review still reads the plan of the work under way, not the held message's" || bad "the held message replaced the run's plan: $(head -c 200 "$IDIR/plan.md" 2>/dev/null)"
  grep -lq "HELD-TASK $who" "$IDIR/held"/*.json 2>/dev/null && ok "his message is kept beside the run" || bad "the held message is gone"
  jq -e --arg id "$mid" 'select(.stage == "pipeline" and .state == "failed" and .held == true and .message_id == $id)' "$(run_events_file "$IDIR")" >/dev/null 2>&1 \
    && ok "and the chat is told the step failed and the message was held" || bad "no held event for the app"
done
echo "===== the triage leaves a required role out: the work goes on without it, and says so ====="
pkill -f "message-pump.sh $SLUG" 2>/dev/null || true; no_pump
PP="$SUPERVISOR_STATE_DIR/pipelines/pick-chat"; mkdir -p "$PP"
cat > "$PP/pipeline.json" <<'JSON'
{"schema":"bulava.pipeline/1","id":"pick-chat","name":"За задачею","description":"тест","revision":1,
 "nodes":[
  {"id":"chat","module":"bulava/trigger.chat@1"},
  {"id":"context","module":"bulava/prep.context@1"},
  {"id":"triage","module":"bulava/prep.classify@1","title":"Тріаж"},
  {"id":"ba","module":"bulava/prep.position@1","title":"Бізнес-аналітик","params":{"engine":"codex","when":"triage","required":true},"prompt":"BA-PICK: {{TASK}}"},
  {"id":"qa","module":"bulava/prep.position@1","title":"Тестувальник","params":{"engine":"claude","required":true},"prompt":"QA-PICK: {{TASK}}"},
  {"id":"agree","module":"bulava/prep.align@1","title":"Домовленість","params":{"required":true}},
  {"id":"compose","module":"bulava/prep.compose@1"},
  {"id":"deliver","module":"bulava/agent.claude@1"},
  {"id":"review","module":"bulava/gate.review@1"},
  {"id":"merge","module":"bulava/out.merge@1"}],
 "edges":[
  {"from":"chat.task","to":"context.task"},{"from":"chat.task","to":"triage.task"},
  {"from":"context.context","to":"ba.context"},{"from":"triage.context","to":"ba.context"},
  {"from":"context.context","to":"qa.context"},{"from":"triage.context","to":"qa.context"},
  {"from":"ba.position","to":"agree.positions"},{"from":"qa.position","to":"agree.positions"},
  {"from":"agree.checks","to":"compose.in"},{"from":"compose.brief","to":"deliver.brief"},
  {"from":"deliver.work","to":"review.work"},{"from":"review.pass","to":"merge.work"},{"from":"review.fail","to":"deliver.feedback","loop":{"max":3}}]}
JSON
# A new task, so the triage runs: a follow-up keeps the steps its task was opened with.
rm -rf "$REC"/* "$IDIR/held" "$IDIR/thread" "$IDIR/done" "$IDIR/outcome.json" "$IDIR/roles-chosen.json"; : > "$REC/injected.txt"
export STUB_PICK_JSON='{"roles":[{"id":"ba","run":false,"why":"PICK-WHY-SENTINEL дрібна правка"}]}'
STUB_SLEEP=0 send "PICK-TASK виправ опечатку в кнопці" "77777777-7777-7777-7777-777777777781" pick-chat >/dev/null
wait_quiet 120 || bad "the pump never finished the pick pipeline"
unset STUB_PICK_JSON
pkill -f "message-pump.sh $SLUG" 2>/dev/null || true
[ -s "$REC/codex-pick.prompt" ] && grep -q "Бізнес-аналітик" "$REC/codex-pick.prompt" \
  && ok "the triage was asked which steps this task needs" || bad "no pick call"
! grep -lq "BA-PICK" "$REC"/codex-brief-*.prompt 2>/dev/null && ok "the analyst it left out never ran" || bad "the analyst ran anyway"
grep -lq "QA-PICK" "$REC"/claude-*.prompt 2>/dev/null && ok "the tester, always called, ran" || bad "the tester did not run"
jq -e 'select(.stage == "ba" and .state == "skipped" and .reason == "triage")' "$(run_events_file "$IDIR")" >/dev/null 2>&1 \
  && ok "the chat shows the analyst as skipped by the triage" || bad "no skipped event for the analyst: $(grep '"ba"' "$(run_events_file "$IDIR")" | tail -2)"
ap="$(ls "$REC"/codex-align-*.prompt 2>/dev/null | head -1)"
[ -n "$ap" ] && grep -q "цього разу не кликали" "$ap" && grep -q "PICK-WHY-SENTINEL" "$ap" \
  && ok "the agreement ran on the one role, told why the other was not called" || bad "agreement: $(head -c 300 "$ap" 2>/dev/null)"
inj="$(cat "$REC/injected.txt")"
case "$inj" in *"PICK-TASK"*"Бізнес-аналітик"*"цього разу не кликали"*) ok "the worker got the task, with the analyst named as not called" ;;
  *) bad "the worker's prompt: $(printf '%s' "$inj" | head -c 400)" ;; esac
! jq -e 'select(.stage == "pipeline" and .held == true and .message_id == "77777777-7777-7777-7777-777777777781")' "$(run_events_file "$IDIR")" >/dev/null 2>&1 \
  && ok "a required role the triage left out does not hold the message" || bad "the message was held"

echo
[ "$fails" = 0 ] && echo "✅ chat pipeline: all passed" || echo "❌ chat pipeline: $fails failure(s)"
exit "$fails"
