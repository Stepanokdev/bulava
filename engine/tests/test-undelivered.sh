#!/bin/bash
# A message the worker could not receive must not vanish.
#
# The reviewer asks for a remediation through worker-send.sh, which types it into the worker's
# session and confirms a turn started. When the session is blocked on a usage limit, Claude Code
# ACCEPTS the keystrokes and refuses to submit them — so the text sat in the composer, the run
# finished as if nothing had been asked, and the fix was never made. The director photographed
# exactly this: «fix done_this_week…» sitting unsent under a finished run.
#
# Now: the composer is cleared (our text never stays behind), the message is parked, and the
# watchdog carries it once the session can run again.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; tmux kill-session -t "$SESSION" 2>/dev/null' EXIT
export SUPERVISOR_STATE_DIR="$TMP/state"
mkdir -p "$SUPERVISOR_STATE_DIR"
. "$BIN_DIR/supervisor-lib.sh"

IDIR="$TMP/idir"; mkdir -p "$IDIR"
# The parked queue no longer lives in the run's folder — ask the engine for its path.
Q="$(undelivered_file "$IDIR")"; STUCK="$(undelivered_stuck_file "$IDIR")"
SESSION="undeliv-$$"
MSG="polagod done_this_week - compare ISO year and week"

# Fast timings: this suite is about the bookkeeping, not about waiting.
export SUPERVISOR_INJECT_ENTER_TRIES=1
export SUPERVISOR_INJECT_SETTLE=1
export SUPERVISOR_PROMPT_WAIT=2
# The pane in these cases never becomes a prompt that accepts anything, so every attempt spends
# its waits in full. What is under test is that the retries are BOUNDED and that the message is
# moved aside rather than lost — neither of which is a matter of how long each doomed attempt
# takes. Short waits, same proof, a minute back.
export SUPERVISOR_INJECT_CALM=1
export SUPERVISOR_INJECT_TYPE_TRIES=1
export SUPERVISOR_TURN_PROBE_GAP=0.2
export SUPERVISOR_ENTER_CONFIRM_WAIT=1

echo "===== parking and carrying a message ====="

MESSAGE_ID="123E4567-E89B-12D3-A456-426614174000"
park_undelivered "$IDIR" "$MSG" "$MESSAGE_ID"
[ -s "$Q" ] && ok "the message is on disk, not lost" \
                                 || bad "nothing was parked"
grep -q "done_this_week" "$Q" 2>/dev/null \
  && ok "its text is intact" || bad "the text did not survive parking"
grep -q "$MESSAGE_ID" "$Q" 2>/dev/null \
  && ok "the app message id survives for a durable queue badge" \
  || bad "the queued message can no longer be matched to its chat row"

# A pane that shows a prompt and accepts keystrokes but never starts a turn — a usage-limited
# Claude Code. Chunked reads so it keeps up under load (see test-resume-composer).
STUB="$TMP/limited.py"
cat > "$STUB" <<'PYSTUB'
# A faithful little composer: printable keys land, Enter does NOT submit (that is the usage-limit
# state being modelled), and C-u kills the line — which is how clear_composer takes text back out.
# Chunked reads so it keeps up under load; a per-character shell loop starved and dropped input.
import os, sys

PROMPT = b"\xe2\x9d\xaf "   # ❯

def redraw(buf):
    os.write(1, b"\r\x1b[2K" + PROMPT + buf)

buf = b""
redraw(buf)
fd = sys.stdin.fileno()
while True:
    chunk = os.read(fd, 4096)
    if not chunk:
        break
    for byte in chunk:
        b = bytes([byte])
        if b == b"\x15":          # C-u — kill the line
            buf = b""
            redraw(buf)
        elif b in (b"\r", b"\n"):  # Enter does nothing: nothing is submitted
            pass
        elif b == b"\x1b":         # Escape — dismisses a menu, leaves the text
            pass
        else:
            buf += b
            os.write(1, b)
PYSTUB
tmux kill-session -t "$SESSION" 2>/dev/null
tmux new-session -d -s "$SESSION" -x 400 -y 30 "bash -c 'stty raw -echo; exec python3 $STUB'" 2>/dev/null
sleep 1

if tmux has-session -t "$SESSION" 2>/dev/null; then
  # Delivery must FAIL on a pane that never starts a turn, and the file must keep the message.
  if flush_undelivered "$SESSION" "$IDIR"; then
    bad "claimed delivery into a pane that never ran a turn"
  else
    ok "refused to claim delivery when no turn started"
  fi
  [ -s "$Q" ] && ok "the message is still parked for a later attempt" \
                                   || bad "the message was dropped after a failed delivery"

  # And our text must not be left sitting in the box.
  if composer_pending "$SESSION" "done_this_week"; then
    bad "our text was left in the composer — the exact bug this fixes"
  else
    ok "the composer was cleared after the failed submit"
  fi
else
  bad "could not start the stub pane"
fi

echo "===== retrying is bounded — a wedged session cannot swallow a message forever ====="

# A session that is alive, draws its prompt, accepts keystrokes and refuses every Enter was found
# in the wild hours after its run had finished. Retrying into it forever leaves a message neither
# delivered nor lost.
rm -f "$Q" "$STUCK" "$IDIR/findings.jsonl"
park_undelivered "$IDIR" "$MSG"
for attempt in 1 2 3; do flush_undelivered "$SESSION" "$IDIR" >/dev/null 2>&1; done

[ -f "$Q" ] && bad "still retrying after the cap" \
                                 || ok "stopped retrying at the cap"
[ -s "$STUCK" ] && ok "the message was moved aside, not deleted" \
                                       || bad "the message was destroyed at the cap"
grep -q "done_this_week" "$IDIR/findings.jsonl" 2>/dev/null \
  && ok "the run files it, so it reaches the report" \
  || bad "nothing filed — the undelivered fix would be invisible"
grep -q '"kind":"blocker"' "$IDIR/findings.jsonl" 2>/dev/null \
  && ok "filed as a blocker, not as a stray note" || bad "wrong finding class"

echo "===== an empty queue is a no-op ====="

rm -f "$Q"
flush_undelivered "$SESSION" "$IDIR" && bad "claimed a delivery with nothing parked" \
                                     || ok "nothing parked, nothing claimed"

echo "===== a malformed line cannot wedge the queue ====="

printf 'not json at all\n' > "$Q"
park_undelivered "$IDIR" "$MSG"
flush_undelivered "$SESSION" "$IDIR" >/dev/null 2>&1
if [ "$(wc -l < "$Q" | tr -d ' ')" = "1" ]; then
  ok "the unreadable line was dropped and the real one kept"
else
  bad "a bad line blocks the queue forever ($(wc -l < "$Q") lines left)"
fi

echo "===== order is preserved =====" 

rm -f "$Q"
park_undelivered "$IDIR" "first"
park_undelivered "$IDIR" "second"
head -1 "$Q" | grep -q "first" \
  && ok "the oldest message is delivered first" || bad "queue order is wrong"

echo
if [ "$fails" -eq 0 ]; then echo "RESULT: all passed, 0 failed"; else echo "RESULT: $fails failed"; fi
exit "$fails"
