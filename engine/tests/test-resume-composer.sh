#!/bin/bash
# Regression: the watchdog must never stack copies of its resume prompt in the composer.
#
# The failure this reproduces, reported with a screenshot: Claude Code hit its session
# limit, the watchdog typed "Carry on with the current task…" with a blind
# `send-keys "$text" Enter`, the limit-blocked CLI accepted the keystrokes and refused to
# submit — and the watchdog, still seeing the banner, repeated it every 15 minutes. Ten
# copies of the sentence ended up in the input box, nothing continued after the limit
# reset, and the director cleared it by hand.
#
# A real tmux session stands in for the CLI. `cat` gives us a genuine tty with line
# discipline, so C-u really kills the line and typed text really echoes — the same
# mechanics the helpers rely on. `_turn_running` is stubbed to say "no turn started",
# which is precisely the limit-blocked behaviour.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()   { printf '  ✅ %s\n' "$1"; }
bad()  { printf '  ❌ %s\n' "$1"; fails=$((fails + 1)); }
have() { command -v "$1" >/dev/null 2>&1; }

have tmux || { echo "SKIP: tmux not installed"; exit 0; }

# An isolated supervisor state dir, so nothing here touches the real one.
export SUP_STATE_OVERRIDE=""
TMP="$(mktemp -d)"
export SUPERVISOR_STATE_DIR="$TMP/state"
mkdir -p "$SUPERVISOR_STATE_DIR"
IDIR="$TMP/instance"; mkdir -p "$IDIR"

. "$BIN_DIR/supervisor-lib.sh"

SESSION="resume-test-$$"
PROMPT="Продовжуй роботу над поточною задачею. Працюй за специфікацією."
NEEDLE="Продовжуй роботу над поточною"

cleanup() { tmux kill-session -t "$SESSION" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

# A pane that shows a prompt marker and echoes what is typed, accepting nothing.
tmux new-session -d -s "$SESSION" -x 120 -y 30 \
  "printf '❯ '; cat > /dev/null" 2>/dev/null || { echo "SKIP: cannot start tmux"; exit 0; }
sleep 1

# The CLI is blocked: no turn ever starts.
_turn_running() { return 1; }

count_in_composer() {   # occurrences of the needle at/after the last prompt marker
  tmux capture-pane -pt "$SESSION" 2>/dev/null | awk -v n="$NEEDLE" '
    /❯/ { buf = "" }
    { buf = buf $0 }
    END {
      c = 0; i = index(buf, n)
      while (i > 0) { c++; buf = substr(buf, i + length(n)); i = index(buf, n) }
      print c
    }'
}

echo "===== composer_pending / clear_composer ====="
tmux send-keys -t "$SESSION" -l "$NEEDLE" 2>/dev/null; sleep 1
if composer_pending "$SESSION" "$NEEDLE"; then ok "pending text is detected"; else bad "typed text not detected as pending"; fi
if clear_composer "$SESSION"; then ok "clear_composer ran"; else bad "clear_composer refused with no turn running"; fi
sleep 1
if composer_pending "$SESSION" "$NEEDLE"; then bad "composer still holds the text after clearing"; else ok "composer is empty after clearing"; fi

echo "===== the bug: repeated resumes must not stack ====="
SUPERVISOR_RESUME_MAX_ATTEMPTS=3
SUPERVISOR_INJECT_SETTLE=0
# Every resume below is meant to FAIL to start a turn, so the confirmation window is spent in
# full each time. One second proves it exactly as six did.
SUPERVISOR_RESUME_CONFIRM_WAIT=1
export SUPERVISOR_TURN_PROBE_GAP=0.2
export SUPERVISOR_ENTER_CONFIRM_WAIT=1
for i in 1 2 3; do
  resume_worker "$SESSION" "$IDIR" "$PROMPT" "$NEEDLE" && bad "attempt $i reported success though no turn started"
done
n="$(count_in_composer)"
if [ "${n:-0}" -le 1 ]; then ok "composer holds at most one copy after 3 attempts (found $n)"
else bad "composer stacked $n copies — this is the reported bug"; fi

echo "===== escalation instead of typing forever ====="
attempts="$(cat "$IDIR/resume-attempts" 2>/dev/null || echo 0)"
if [ "$attempts" -ge 3 ]; then ok "attempts are counted and persisted ($attempts)"; else bad "attempts not counted (got '$attempts')"; fi
if [ -f "$IDIR/stalled.json" ]; then ok "run parked for a human (stalled.json)"; else bad "no park after the attempt cap"; fi
if [ -e "$IDIR/resume-refused" ]; then ok "refusal marker written, so the park survives a pane change"
else bad "no resume-refused marker — the watchdog's note_activity would erase the park"; fi
if grep -q "resume" "$IDIR/stalled.json" 2>/dev/null; then ok "the park says why"; else bad "park has no reason"; fi

# A further call must not type anything more — it is capped.
before="$(count_in_composer)"
resume_worker "$SESSION" "$IDIR" "$PROMPT" "$NEEDLE"
after="$(count_in_composer)"
if [ "$before" = "$after" ]; then ok "capped: nothing typed after the park"; else bad "kept typing after the park ($before → $after)"; fi

echo "===== a limit-blocked pane: keystrokes land, Enter does nothing ====="
# The harness above uses `cat`, whose tty accepts Enter — so it cannot reproduce the
# stacking itself. This one echoes printable keys and DROPS carriage returns, which is what
# a usage-limited Claude Code does: the text goes in, submitting does not work. First prove
# the harness really reproduces the reported bug with the old blind approach, then prove the
# new path does not.
BLOCKED="resume-blocked-$$"
tmux kill-session -t "$BLOCKED" 2>/dev/null
# The stub reads in CHUNKS, not one character per shell read, and lives in a file rather than a
# nest of quotes.
#
# It used to be `while IFS= read -rsn1 c` in bash, which does a syscall and a loop iteration per
# character. Under real load — a worker grinding in another pane, a build running — it could not
# keep up with `send-keys` and the tty DISCARDED input: the pane ended up holding one copy plus
# the last two characters of the next, so the control assert reported "the harness cannot
# reproduce the bug" when the harness was merely starved. Chunked reads with unbuffered writes
# keep up, and the modelled behaviour is unchanged: printable keys land, Enter does nothing.
STUB="$TMP/limited-pane.py"
cat > "$STUB" <<'PYSTUB'
import os, sys
sys.stdout.write("\u276f ")
sys.stdout.flush()
fd = sys.stdin.fileno()
while True:
    chunk = os.read(fd, 4096)
    if not chunk:
        break
    chunk = chunk.replace(b"\r", b"").replace(b"\n", b"")
    if chunk:
        os.write(1, chunk)
PYSTUB
tmux new-session -d -s "$BLOCKED" -x 400 -y 30 \
  "bash -c 'stty raw -echo; exec python3 $STUB'" 2>/dev/null
sleep 1

# How many copies of the needle the pane holds, counted across joined rows (a wrapped copy
# must still count once).
#
# Not awk: BSD awk's `index()` counts CHARACTERS while `length()` counts BYTES unless the
# locale says otherwise, and the needle is Cyrillic — so advancing by `length(n)` jumped
# roughly twice as far as it should and copies were skipped. It reported "1 copy" for a pane
# holding three, which read as a broken harness and depended on whether LANG happened to be
# set. Python counts characters consistently either way.
count_in() {  # $1 = session
  tmux capture-pane -pt "$1" 2>/dev/null | python3 -c '
import sys
needle = sys.argv[1]
buf = "".join(line.rstrip("\n") for line in sys.stdin)
print(buf.count(needle))
' "$NEEDLE"
}

if tmux has-session -t "$BLOCKED" 2>/dev/null; then
  # Control: the old code — type, press Enter, hope. Three ticks.
  #
  # Wait for each copy to actually be echoed instead of sleeping a fixed second: on a machine
  # busy with a real worker the stub's echo lags, and a fixed sleep made this control assert
  # fail intermittently — reporting a broken harness when only the timing was off.
  for i in 1 2 3; do
    tmux send-keys -t "$BLOCKED" -l "$PROMPT" 2>/dev/null
    tmux send-keys -t "$BLOCKED" Enter 2>/dev/null
    for _ in $(seq 1 40); do
      [ "$(count_in "$BLOCKED")" -ge "$i" ] && break
      sleep 0.25
    done
  done
  control="$(count_in "$BLOCKED")"
  # Two is enough to prove the harness reproduces stacking: the fixed path leaves 0–1, so any
  # count above one is behaviour this test can distinguish. Demanding exactly three made the
  # check depend on pane geometry and echo timing rather than on the bug.
  if [ "${control:-0}" -ge 2 ]; then ok "harness reproduces the bug: blind resumes stacked $control copies"
  else bad "harness did not reproduce the stacking (got $control) — the check below proves nothing"; fi

  # Now the real path, on a pane that already holds the mess. It must not add more.
  tmux kill-session -t "$BLOCKED" 2>/dev/null
  tmux new-session -d -s "$BLOCKED" -x 400 -y 30 \
    "bash -c 'stty raw -echo; printf \"❯ \"; while IFS= read -rsn1 c; do case \"\$c\" in \$\"\\r\"|\$\"\\n\") ;; *) printf \"%s\" \"\$c\" ;; esac; done'" 2>/dev/null
  sleep 1
  IDIR2="$TMP/instance2"; mkdir -p "$IDIR2"
  for i in 1 2 3; do resume_worker "$BLOCKED" "$IDIR2" "$PROMPT" "$NEEDLE"; done
  after="$(count_in "$BLOCKED")"
  if [ "${after:-0}" -le 1 ]; then ok "three resumes on a blocked pane left $after copy in the composer"
  else bad "stacked $after copies on a blocked pane — the bug is not fixed"; fi
  if [ -f "$IDIR2/stalled.json" ]; then ok "blocked pane parked for a human"; else bad "blocked pane never escalated"; fi
  tmux kill-session -t "$BLOCKED" 2>/dev/null
else
  echo "  (skipped: could not start the blocked-pane harness)"
fi

echo "===== a working turn clears the state ====="
_turn_running() { return 0; }
if resume_worker "$SESSION" "$IDIR" "$PROMPT" "$NEEDLE"; then ok "a running turn counts as resumed"; else bad "running turn reported as refusal"; fi
if [ ! -f "$IDIR/resume-attempts" ] && [ ! -f "$IDIR/stalled.json" ] && [ ! -e "$IDIR/resume-refused" ]; then
  ok "attempt count and park cleared once the worker is working"
else bad "state left behind after a successful resume"; fi


# --- Injecting into a session that is still working ------------------------------------
#
# A `night-shift stop` leaves the tmux session alive while removing the instance dir and the
# watchdog, so a session can outlive its supervision. A dispatch then REUSED that session and
# typed a second mission into a worker that was mid-turn on the first — while the app, seeing an
# instance with no watchdog, resolved the task to FAILED. `inject_task` must wait for an IDLE
# prompt, not merely a prompt that is drawn.
echo "===== inject_task must not type into a worker mid-turn ====="
# The section above stubbed `_turn_running` to always say "a turn is running". Restore the real
# one, or this block would only be testing the stub.
. "$BIN_DIR/supervisor-lib.sh"
BUSY="inject-busy-$$"
tmux kill-session -t "$BUSY" 2>/dev/null
# A pane that shows both a prompt line AND a running-turn footer — exactly what Claude Code
# looks like while it works.
tmux new-session -d -s "$BUSY" -x 120 -y 20 \
  "printf '❯ \nesc to interrupt\n'; sleep 300" 2>/dev/null
sleep 1
if tmux has-session -t "$BUSY" 2>/dev/null; then
  # The waits here are what the injection spends when nothing answers, and every one of them is
  # dead time in a test: the stub pane never starts a turn, so the Enter loop runs its full course
  # whatever it is set to. Short values prove the same thing in seconds instead of a minute.
  SUPERVISOR_PROMPT_WAIT=3 SUPERVISOR_INJECT_CALM=1 SUPERVISOR_INJECT_ENTER_TRIES=1 INJECT_LOG=/dev/null
  export SUPERVISOR_PROMPT_WAIT SUPERVISOR_INJECT_CALM SUPERVISOR_INJECT_ENTER_TRIES INJECT_LOG
  inject_task "$BUSY" "SECOND-MISSION-DO-NOT-TYPE"; rc=$?
  if [ "$rc" != 0 ]; then ok "refused to inject into a busy worker (rc=$rc)"; else bad "injected into a busy worker"; fi
  if tmux capture-pane -pt "$BUSY" 2>/dev/null | grep -q "SECOND-MISSION"; then
    bad "the second mission was typed into a working session"
  else ok "nothing was typed into the working session"; fi
  tmux kill-session -t "$BUSY" 2>/dev/null

  # …and an IDLE prompt still accepts work, or dispatch would never start anything.
  IDLE="inject-idle-$$"
  tmux new-session -d -s "$IDLE" -x 120 -y 20 "printf '❯ '; cat > /dev/null" 2>/dev/null
  sleep 1
  inject_task "$IDLE" "FIRST-MISSION" >/dev/null 2>&1
  if tmux capture-pane -pt "$IDLE" 2>/dev/null | grep -q "FIRST-MISSION"; then
    ok "an idle prompt still receives the task"
  else bad "an idle session no longer accepts a task — dispatch would never start"; fi
  tmux kill-session -t "$IDLE" 2>/dev/null
else
  echo "  (skipped: could not start the busy-pane harness)"
fi

echo
[ "$fails" = 0 ] && { echo "✅ test-resume-composer PASSED"; exit 0; }
echo "❌ test-resume-composer FAILED ($fails)"; exit 1
