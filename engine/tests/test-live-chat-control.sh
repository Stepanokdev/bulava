#!/bin/bash
# A busy direct chat queues immediately, and Stop interrupts only its current turn.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
export HOME="$TMP/home"; mkdir -p "$HOME/.claude/sessions"
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
. "$BIN_DIR/supervisor-lib.sh"

PROJECT="$TMP/project"; mkdir -p "$PROJECT"
SLUG="$(slug_for "$PROJECT")"; IDIR="$SUP_INSTANCES/$SLUG"; mkdir -p "$IDIR"
# The parked queue lives outside the run's folder, so it survives the folder — ask for it.
Q="$(undelivered_file "$IDIR")"
SESSION="$(session_name "$SLUG")"; RID="RUN-LIVE-CONTROL"; MESSAGE_ID="123E4567-E89B-12D3-A456-426614174001"
printf '%s\n' "$PROJECT" > "$IDIR/project"
printf '%s\n' "$SESSION" > "$IDIR/session"
printf '%s\n' "$RID" > "$IDIR/run-id"

MARKER="$TMP/escape-byte"
STUB="$TMP/busy.py"
cat > "$STUB" <<'PY'
import os, sys, tty
tty.setraw(sys.stdin.fileno())
print("working · esc to interrupt", flush=True)
byte = os.read(sys.stdin.fileno(), 1)
with open(sys.argv[1], "w") as handle:
    handle.write(str(byte[0]))
PY

trap 'tmux kill-session -t "$SESSION" 2>/dev/null || true; rm -rf "$TMP"' EXIT
tmux new-session -d -s "$SESSION" "python3 '$STUB' '$MARKER'" 2>/dev/null
sleep 1
cat > "$HOME/.claude/sessions/$$.json" <<JSON
{"pid":$$,"sessionId":"test","tmux":"$SESSION:@1.%1","status":"busy"}
JSON

echo "===== a follow-up to a busy chat is a queue operation ====="
out="$(bash "$BIN_DIR/worker-send.sh" --mode conversation --message-id "$MESSAGE_ID" \
       "$PROJECT" - - "$RID" "one more thing" 2>&1)"; rc=$?
[ "$rc" = 2 ] && printf '%s' "$out" | grep -q 'TIER=queued' \
  && ok "the relay returns queued immediately" || bad "busy relay was not an explicit queue (rc=$rc: $out)"
jq -e --arg id "$MESSAGE_ID" 'select(.id == $id and .message == "one more thing")' \
  "$Q" >/dev/null 2>&1 \
  && ok "the exact chat row is durable on disk" || bad "queued row id/message is missing"

echo "===== Stop is Escape, not a killed conversation ====="
if bash "$BIN_DIR/worker-interrupt.sh" "$PROJECT" "$RID" >/dev/null 2>&1; then
  ok "Stop was accepted for the matching run"
else
  bad "Stop failed for the matching live run"
fi
for _ in 1 2 3 4 5; do [ -f "$MARKER" ] && break; sleep 0.2; done
[ "$(cat "$MARKER" 2>/dev/null || true)" = 27 ] \
  && ok "the worker received Escape" || bad "Stop did not reach the Claude terminal"
[ -s "$Q" ] \
  && ok "queued follow-ups survive Stop" || bad "Stop destroyed the message queue"

echo
[ "$fails" = 0 ] && echo "✅ live chat control: all passed" || echo "❌ $fails problem(s)"
exit "$fails"
