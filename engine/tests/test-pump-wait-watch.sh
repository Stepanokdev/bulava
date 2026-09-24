#!/bin/bash
# A queued message must not hide a frozen worker, and a waiting pump must not be "restarted".
#
# What happened: with one director message in the queue, the pump waited for the worker to become
# free — hours, through six review rounds — writing no pipeline marker, because nothing was being
# prepared. The watchdog read the missing marker as "nobody is pumping", spawned a fresh pump every
# 45 seconds (391 times in one afternoon; each exited at the live lock), and counted every such
# "restart" as activity. That activity mark is what the stall check, the idle teardown and the
# frozen-turn recovery are all gated on — so a worker that took its task and froze with a message
# queued could never be seen.
#
# Asserted, on the helper the watchdog now reads instead of the pipeline marker:
#   - a live pump waiting for the worker  → "worker": nothing is marked, the pane's stillness counts
#   - a live pump waiting for Codex / a limit → "external": the wait is the engine's, not the worker's
#   - a dead pump, or no pump              → "restart": the one case that starts a pump
# And on the watchdog itself, with a stand-in pump: one poll with a live waiting pump writes no
# "restarted" line and does not touch last-activity; one poll with the pump gone writes exactly one.
set -u
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d -t pump-wait)" || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
. "$BIN_DIR/supervisor-lib.sh"

PROJ="$TMP/project"; mkdir -p "$PROJ"
SLUG="$(slug_for "$PROJ")"; IDIR="$(instance_dir "$SLUG")"
mkdir -p "$IDIR" "$(pending_dir "$IDIR")"
printf '%s\n' "$PROJ" > "$IDIR/project"
printf 'RUN-1\n' > "$IDIR/run-id"
printf '{"message":"продовжуй","message_id":"m1","seq":"1"}\n' > "$(pending_dir "$IDIR")/00000001-m1.json"

echo "===== the helper: what a non-empty queue means for one poll ====="
[ "$(pending_queue_state "$IDIR")" = restart ] && ok "no pump at all → restart" || bad "no pump should mean restart, got '$(pending_queue_state "$IDIR")'"

sleep 300 & PUMP=$!
mkdir -p "$IDIR/pump.lock"; printf '%s\n' "$PUMP" > "$IDIR/pump.lock/pid"
printf '{"reason":"turn","seq":"1","since":%s}\n' "$(date +%s)" > "$IDIR/queue-wait.json"
[ "$(pending_queue_state "$IDIR")" = worker ] && ok "a live pump waiting for the worker's turn → worker (not activity)" \
  || bad "expected worker, got '$(pending_queue_state "$IDIR")'"
printf '{"reason":"review","seq":"1"}\n' > "$IDIR/queue-wait.json"
[ "$(pending_queue_state "$IDIR")" = worker ] && ok "waiting on a review → worker" || bad "review wait should read as worker"
rm -f "$IDIR/queue-wait.json"
[ "$(pending_queue_state "$IDIR")" = worker ] && ok "a live pump with no published reason → worker" || bad "no reason should default to worker"
printf '{"reason":"codex","seq":"1"}\n' > "$IDIR/queue-wait.json"
[ "$(pending_queue_state "$IDIR")" = external ] && ok "waiting for Codex → external (still counts as the engine's wait)" \
  || bad "expected external, got '$(pending_queue_state "$IDIR")'"
printf '{"reason":"limit","seq":"1"}\n' > "$IDIR/queue-wait.json"
[ "$(pending_queue_state "$IDIR")" = external ] && ok "waiting on a usage limit → external" || bad "limit wait should read as external"

kill "$PUMP" 2>/dev/null; wait "$PUMP" 2>/dev/null || true
[ "$(pending_queue_state "$IDIR")" = restart ] && ok "a dead pump behind a stale lock → restart" \
  || bad "a dead pid must not pass for a live pump"

echo "===== the watchdog's own branch, one poll at a time ====="
# The branch is exercised by running the watchdog loop body against a stand-in tmux and pump. tmux
# is replaced by a stub that says the session exists and captures a constant pane; the pump command
# is a stub that records it was started. One poll is enough, so POLL is tiny and the loop is left by
# removing the instance directory from under it.
mkdir -p "$TMP/stub"
cat > "$TMP/stub/tmux" <<'EOF'
#!/bin/bash
case "$1" in
  has-session) exit 0 ;;
  capture-pane) printf 'still\n'; exit 0 ;;
  display-message) printf '%%0\n'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
cat > "$TMP/stub/pump" <<'EOF'
#!/bin/bash
echo started >> "$PUMP_STARTED"
EOF
chmod +x "$TMP/stub/tmux" "$TMP/stub/pump"
export PUMP_STARTED="$TMP/pump-started"
: > "$PUMP_STARTED"
printf 'night-%s\n' "$SLUG" > "$IDIR/session"

sleep 300 & PUMP=$!
printf '%s\n' "$PUMP" > "$IDIR/pump.lock/pid"
printf '{"reason":"turn","seq":"1"}\n' > "$IDIR/queue-wait.json"
: > "$SUPERVISOR_STATE_DIR/watchdog.log"
( PATH="$TMP/stub:$PATH" SUPERVISOR_WATCHDOG_POLL=1 SUPERVISOR_PUMP_CMD="$TMP/stub/pump" \
  SUPERVISOR_CLAUDE_USAGE_CMD=/usr/bin/true \
  SUPERVISOR_CODEX_USAGE_CMD=/usr/bin/true SUPERVISOR_HUNG_RECOVERIES=0 \
  bash "$BIN_DIR/watchdog.sh" "$SLUG" >/dev/null 2>&1 ) &
WD=$!
# The very first poll always notes activity — the pane hash is new to it. The claim is about the
# polls after that, so the clock is set back once the watchdog has seen the pane, and read again
# after two more polls.
sleep 2
# Set back by a minute — far short of the stall and idle deadlines, whose firing is not the claim.
touch -A -000100 "$IDIR/last-activity"
before="$(stat -f %m "$IDIR/last-activity")"
sleep 3
kill "$WD" 2>/dev/null; wait "$WD" 2>/dev/null || true
n="$(grep -c 'restarted the message pump' "$SUPERVISOR_STATE_DIR/watchdog.log" 2>/dev/null)"; n="${n:-0}"
[ "$n" = 0 ] && ok "a live waiting pump is not 'restarted' by the watchdog" || bad "the watchdog logged $n restart(s) with a live pump"
[ ! -s "$PUMP_STARTED" ] && ok "and no second pump was spawned" || bad "a second pump was spawned beside the live one"
after="$(stat -f %m "$IDIR/last-activity")"
[ "$after" = "$before" ] && ok "last-activity was left alone — waiting is not work" || bad "the wait was counted as activity (last-activity moved)"
kill "$PUMP" 2>/dev/null; wait "$PUMP" 2>/dev/null || true

rm -rf "$IDIR/pump.lock" "$IDIR/queue-wait.json"
: > "$SUPERVISOR_STATE_DIR/watchdog.log"; : > "$PUMP_STARTED"
( PATH="$TMP/stub:$PATH" SUPERVISOR_WATCHDOG_POLL=1 SUPERVISOR_PUMP_CMD="$TMP/stub/pump" \
  SUPERVISOR_CLAUDE_USAGE_CMD=/usr/bin/true \
  SUPERVISOR_CODEX_USAGE_CMD=/usr/bin/true SUPERVISOR_HUNG_RECOVERIES=0 \
  bash "$BIN_DIR/watchdog.sh" "$SLUG" >/dev/null 2>&1 ) &
WD=$!
sleep 2
kill "$WD" 2>/dev/null; wait "$WD" 2>/dev/null || true
[ -s "$PUMP_STARTED" ] && ok "with no pump alive the watchdog starts one" || bad "no pump was started for an orphaned queue"
grep -q 'restarted the message pump' "$SUPERVISOR_STATE_DIR/watchdog.log" 2>/dev/null \
  && ok "and says so once" || bad "the restart was not logged"

echo
[ "$fails" = 0 ] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
