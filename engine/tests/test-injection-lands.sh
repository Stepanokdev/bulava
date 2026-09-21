#!/bin/bash
# A task that never reached the worker, reported as delivered.
#
# The director dispatched work at 20:26. The launcher logged `inject rc=0`. Sixteen minutes later
# the worker was still sitting at an empty prompt, had written no transcript, and the app could
# only say "I cannot find the session log for this run". Three separate lies in a row, and the
# root of all of them was one clause: `_turn_running` treated "the pane changed in the last
# second" as proof that a turn had started. A freshly launched Claude Code animates its welcome
# panel, so the check passed while the CLI was still booting — the keystrokes went into a terminal
# that was not listening yet, and nothing was ever submitted.
#
# What is pinned here: a redraw is not a turn, the CLI's own status is believed when it exists,
# and typing that changes nothing on screen is retried instead of being called a success.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; tmux kill-session -t "$SESSION" 2>/dev/null || true' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME/.claude/sessions"
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
. "$BIN_DIR/supervisor-lib.sh"

SESSION="bulava-inject-test-$$"

echo "===== the CLI's own status is the answer when it keeps one ====="

tmux new-session -d -s "$SESSION" "bash -c 'while :; do printf \"\\r%s\" \"\$RANDOM\"; sleep 0.2; done'" 2>/dev/null
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "  ⚠️  tmux unavailable — skipping the live half"
else
  cat > "$HOME/.claude/sessions/$$.json" <<JSON
{"pid":$$,"sessionId":"deadbeef","tmux":"$SESSION:@1.%1","status":"idle"}
JSON
  # The pane above repaints every 200ms — exactly the shape that used to read as a running turn.
  if _turn_running "$SESSION"; then
    bad "a repainting pane still reads as a running turn"
  else
    ok "a pane that merely redraws is not a turn"
  fi

  if [ "$(worker_status "$SESSION")" = "idle" ]; then ok "the session file is found by tmux name"
  else bad "worker_status did not find the session (got: $(worker_status "$SESSION" 2>&1))"; fi

  sed -i '' 's/"status":"idle"/"status":"busy"/' "$HOME/.claude/sessions/$$.json"
  if _turn_running "$SESSION"; then ok "busy is believed"; else bad "a busy CLI read as idle"; fi

  # A dead pid is a leftover file, not a live worker.
  cat > "$HOME/.claude/sessions/999999.json" <<JSON
{"pid":999999,"sessionId":"stale","tmux":"$SESSION:@1.%1","status":"busy"}
JSON
  rm -f "$HOME/.claude/sessions/$$.json"
  if worker_status "$SESSION" >/dev/null 2>&1; then
    bad "a session file whose process is gone was believed"
  else
    ok "a leftover session file is ignored"
  fi
fi

echo
echo "===== without a session file, only the CLI's own marker counts ====="

if _pane_says_turn_running '✻ Churning… (12s · esc to interrupt)'; then
  ok "'esc to interrupt' is still the marker"
else
  bad "the marker stopped being recognised"
fi
if _pane_says_turn_running 'Welcome back Ivan!   ▐▛███▜▌'; then
  bad "a welcome banner reads as a running turn"
else
  ok "a welcome banner is not a turn"
fi

echo
echo "===== typing that lands nowhere is retried, not reported as sent ====="
# The retry loop is what turns "the keystrokes vanished" into a second attempt. Asserted on the
# source because the alternative is a test that has to boot a real CLI to lose a keystroke.
if grep -q 'typing left the screen unchanged — retrying' "$BIN_DIR/supervisor-lib.sh" \
   && grep -q 'SUPERVISOR_INJECT_TYPE_TRIES' "$BIN_DIR/supervisor-lib.sh"; then
  ok "injection verifies the text landed and retries when it did not"
else
  bad "injection types once and hopes"
fi
if grep -q 'SUPERVISOR_INJECT_CALM' "$BIN_DIR/supervisor-lib.sh"; then
  ok "injection waits for the screen to settle before typing"
else
  bad "injection types into a still-booting TUI"
fi

echo
echo "===== the handoff says where it has got to, against a real pane ====="
#
# Taking a message back has to answer differently on the two sides of the Enter key, and the only
# thing that can tell them apart is the injection itself. Everything downstream trusts this
# sequence, so it is asserted here against a real tmux session rather than a stub of it.
PHASE_SESSION="bulava-phase-test-$$"
tmux kill-session -t "$PHASE_SESSION" 2>/dev/null
# A pane that behaves like a composer: it shows the prompt marker, and once a line is submitted it
# says the turn is running the way the CLI does — through its own status file.
SESSFILE="$HOME/.claude/sessions/phase.json"
cat > "$TMP/pane.sh" <<PANE
#!/bin/bash
printf '\n❯ '
while IFS= read -r line; do
  printf '%s\n' "\$(date +%s)" > "$TMP/submitted-at"
  python3 - <<'PY2'
import json, os
p = "$SESSFILE"
d = json.load(open(p)); d["status"] = "busy"; json.dump(d, open(p, "w"))
PY2
  printf 'working…\n'
  while :; do sleep 1; done
done
PANE
chmod +x "$TMP/pane.sh"
cat > "$SESSFILE" <<JSON
{"pid":$$,"sessionId":"phasetest","tmux":"$PHASE_SESSION:@1.%1","status":"idle"}
JSON
tmux new-session -d -s "$PHASE_SESSION" "bash '$TMP/pane.sh'" 2>/dev/null
if ! tmux has-session -t "$PHASE_SESSION" 2>/dev/null; then
  echo "  ⚠️  tmux unavailable — skipping the phase sequence"
else
  sleep 1
  # Read from the trail the injection itself appends, not by sampling the marker: `typed` and
  # `submitted` can be milliseconds apart, and under a loaded machine a poll loop simply misses one.
  PHASE_FILE="$TMP/phase"; rm -f "$PHASE_FILE.log"
  INJECT_PHASE_FILE="$PHASE_FILE" SUPERVISOR_PROMPT_WAIT=20 SUPERVISOR_INJECT_CALM=0 \
    SUPERVISOR_TURN_PROBE_GAP=0 INJECT_LOG="$TMP/inject.log" \
    inject_task "$PHASE_SESSION" "привіт, це перевірка фаз"
  rc=$?
  SEEN="$PHASE_FILE.log"
  [ "$rc" = 0 ] && ok "the injection completed against a real pane" || bad "injection returned $rc"
  seq="$(awk '{print $3}' "$SEEN" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
  case "$seq" in
    "waiting typing typed submitting submitted confirmed")
      ok "and published waiting → typing → typed → submitting → submitted → confirmed" ;;
    *) bad "the phase sequence was '$seq'" ;;
  esac
  # The one that must never be late: `submitted` is written BEFORE the Enter key, so a withdrawal
  # can never read `typed` on a message that has already gone in.
  grep -q 'submitted' "$SEEN" && [ -e "$TMP/submitted-at" ] \
    && ok "the pane really received the line" || bad "the pane never saw a submitted line"
  tmux kill-session -t "$PHASE_SESSION" 2>/dev/null
fi

echo
echo
echo "===== taking a message back DURING the handoff, against a real pane ====="
#
# The two moments that matter, exercised by the real injection and the real withdrawal rather than
# by a stand-in for either: while the text is being pasted, and after the Enter key has gone in.
# A stub of the injector can only ever prove that the protocol is consistent with itself.
. "$BIN_DIR/supervisor-lib.sh"
WPROJ="$TMP/wproj"; mkdir -p "$WPROJ"
( cd "$WPROJ" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init ) 2>/dev/null
WSLUG="$(slug_for "$WPROJ")"; WIDIR="$(instance_dir "$WSLUG")"; mkdir -p "$WIDIR"
printf '%s\n' "$(canon_path "$WPROJ")" > "$WIDIR/project"
printf '%s\n' "RUN-W" > "$WIDIR/run-id"

start_pane() {   # $1=session  $2=seconds the pane waits before admitting the turn started
  local sess="$1" delay="$2"
  tmux kill-session -t "$sess" 2>/dev/null
  cat > "$TMP/wpane.sh" <<PANE
#!/bin/bash
printf '\n❯ '
while IFS= read -r line; do
  printf '%s\n' "\$line" >> "$TMP/pane-received"
  sleep $delay
  python3 - <<'PY2'
import json
p = "$TMP/wsess.json"
d = json.load(open(p)); d["status"] = "busy"; json.dump(d, open(p, "w"))
PY2
  printf 'working…\n'
  while :; do sleep 1; done
done
PANE
  chmod +x "$TMP/wpane.sh"
  cat > "$TMP/wsess.json" <<JSON
{"pid":$$,"sessionId":"wtest","tmux":"$sess:@1.%1","status":"idle"}
JSON
  ln -sf "$TMP/wsess.json" "$HOME/.claude/sessions/wtest.json" 2>/dev/null || true
  tmux new-session -d -s "$sess" "bash '$TMP/wpane.sh'" 2>/dev/null
  sleep 1
}

# The handoff, started the way the delivery stage starts it, so the withdrawal finds what it
# expects: a marker naming the process, its phase file and its session.
begin_handoff() {   # $1=session  $2=message id  $3=phase file
  jq -nc --arg m "$2" --argjson pid "$4" --arg p "$3" --arg s "$1" \
     '{pid:$pid, phase_file:$p, session:$s, message_id:$m}' > "$(delivering_file "$WIDIR")"
}
await_phase() {    # $1=phase file  $2=phase  $3=seconds
  local i=0
  while [ "$i" -lt $(( ${3:-20} * 20 )) ]; do
    grep -q " $2\$" "$1.log" 2>/dev/null && return 0
    sleep 0.05; i=$((i + 1))
  done
  return 1
}

WSESSION="bulava-withdraw-test-$$"
rm -f "$TMP/pane-received"
start_pane "$WSESSION" 0
if ! tmux has-session -t "$WSESSION" 2>/dev/null; then
  echo "  ⚠️  tmux unavailable — skipping the live withdrawal"
else
  PF="$TMP/wphase"; rm -f "$PF" "$PF.log"
  # A long settle keeps the handoff at `typing` for as long as it takes to notice and act.
  ( INJECT_PHASE_FILE="$PF" SUPERVISOR_PROMPT_WAIT=20 SUPERVISOR_INJECT_CALM=0 \
      SUPERVISOR_INJECT_SETTLE=8 SUPERVISOR_TURN_PROBE_GAP=0 INJECT_LOG="$TMP/inject2.log" \
      inject_task "$WSESSION" "це не має дійти" ) &
  injector=$!
  begin_handoff "$WSESSION" "11111111-2222-3333-4444-555555555555" "$PF" "$injector"
  if await_phase "$PF" typing 25; then
    ok "the real injection can be caught while it is pasting"
    v="$(bash "$BIN_DIR/worker-withdraw.sh" "$WPROJ" "11111111-2222-3333-4444-555555555555")"
    [ "$v" = withdrawn ] && ok "and taking it back then is a real withdrawal" \
      || bad "a live mid-paste withdrawal answered '$v'"
    wait "$injector" 2>/dev/null
    sleep 1
    [ -s "$TMP/pane-received" ] && bad "the pane received a line for a withdrawn message" \
      || ok "the pane never received it"
    pane_now="$(tmux capture-pane -pt "$WSESSION" 2>/dev/null)"
    case "$pane_now" in *"це не має дійти"*) bad "the withdrawn text is still sitting in the composer" ;;
      *) ok "and the composer it had changed was cleared" ;; esac
  else
    bad "the real injection never reported that it was pasting"
    kill "$injector" 2>/dev/null
  fi
  tmux kill-session -t "$WSESSION" 2>/dev/null
fi

WSESSION2="bulava-withdraw-test2-$$"
rm -f "$TMP/pane-received" "$(delivering_file "$WIDIR")"
rm -rf "$WIDIR/withdrawn" "$WIDIR/cancelled" 2>/dev/null
start_pane "$WSESSION2" 6      # the pane takes its time admitting the turn began
if ! tmux has-session -t "$WSESSION2" 2>/dev/null; then
  echo "  ⚠️  tmux unavailable — skipping the post-Enter half"
else
  PF2="$TMP/wphase2"; rm -f "$PF2" "$PF2.log"
  ( INJECT_PHASE_FILE="$PF2" SUPERVISOR_PROMPT_WAIT=20 SUPERVISOR_INJECT_CALM=0 \
      SUPERVISOR_INJECT_SETTLE=0 SUPERVISOR_TURN_PROBE_GAP=0 SUPERVISOR_ENTER_CONFIRM_WAIT=12 \
      INJECT_LOG="$TMP/inject3.log" \
      inject_task "$WSESSION2" "це вже пішло у воркера" ) &
  injector2=$!
  begin_handoff "$WSESSION2" "66666666-7777-8888-9999-000000000000" "$PF2" "$injector2"
  if await_phase "$PF2" submitted 25; then
    ok "the real injection can be caught with the line already sent"
    v="$(bash "$BIN_DIR/worker-withdraw.sh" "$WPROJ" "66666666-7777-8888-9999-000000000000")"
    [ "$v" = already-read ] && ok "and then the only honest answer is that it was read" \
      || bad "a live post-Enter withdrawal answered '$v'"
    wait "$injector2" 2>/dev/null
    [ -s "$TMP/pane-received" ] && ok "the pane really did receive the line" \
      || bad "the answer said 'already read' but the pane got nothing"
  else
    bad "the real injection never reported the line as sent"
    kill "$injector2" 2>/dev/null
  fi
  tmux kill-session -t "$WSESSION2" 2>/dev/null
fi
rm -rf "$WIDIR" 2>/dev/null


[ "$fails" = 0 ] && echo "✅ injection: what is reported delivered was delivered" || echo "❌ $fails problem(s)"
exit "$fails"
