#!/bin/bash
# A chat waiting on a permission dialog is waiting for him, not idle.
#
# The watchdog tears down a run whose screen has not changed for SUPERVISOR_IDLE_KILL_HOURS: it
# kills the tmux session and deletes the run's folder. A question was exempt from that; a
# permission dialog in a chat with a person there was not, so a dialog he had not got to in four
# hours took the chat and its folder with it. Replayed against watchdog.sh itself, with the idle
# deadline cut to seconds:
#   - with a dialog on screen the run and its session are still there past the deadline
#   - the control: once the dialog is answered (the conversation moves on), the same idle run is
#     torn down exactly as before
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$ROOT/bin"
unset SUPERVISOR_UNATTENDED SUPERVISOR_CHAT_CONTEXT_FILE SUPERVISOR_EXTRA_DIRS_FILE
command -v tmux >/dev/null 2>&1 || { echo "SKIP: tmux not installed"; exit 0; }

TMP="$(mktemp -d)"
tmux_isolate "$TMP/tmux"
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
export SUPERVISOR_CLAUDE_USAGE_CMD=/usr/bin/true SUPERVISOR_CODEX_USAGE_CMD=/usr/bin/true
export SUPERVISOR_CLAUDE_REACHABLE_CMD=/usr/bin/true
. "$BIN_DIR/supervisor-lib.sh"
WD=""
trap '[ -n "$WD" ] && kill "$WD" 2>/dev/null; tmux_cleanup; rm -rf "$TMP"' EXIT INT TERM

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

PROJ="$TMP/project"; mkdir -p "$PROJ"; PROJ="$(canon_path "$PROJ")"
SLUG="$(slug_for "$PROJ")"; IDIR="$(instance_dir "$SLUG")"; SESSION="$(session_name "$SLUG")"
mkdir -p "$IDIR"; printf '%s\n' "$PROJ" > "$IDIR/project"; : > "$IDIR/started-at"
printf '%s\n' "$SESSION" > "$IDIR/session"
# A still pane and a transcript that does not move: Claude Code sitting on its dialog.
tmux new-session -d -s "$SESSION" -x 120 -y 30 "cat"
TX="$TMP/transcript.jsonl"; : > "$TX"; touch -t 202601010000 "$TX"
printf 'sid-1' > "$IDIR/claude-session-id"
printf '%s\t%s\n' sid-1 "$TX" > "$IDIR/.transcript-path"
jq -nc --argjson at "$(date +%s)" '{at:$at, message:"Claude needs your permission to use Bash", kind:"permission_prompt"}' \
  > "$IDIR/permission-wait.json"
touch -t 202601010000 "$IDIR/last-activity"

WDLOG="$SUPERVISOR_STATE_DIR/watchdog.log"; : > "$WDLOG"
echo "===== a dialog on screen, a person there, the idle deadline long past ====="
SUPERVISOR_WATCHDOG_POLL=1 SUPERVISOR_IDLE_KILL_SECS=3 SUPERVISOR_STALL_PARK_SECS=2 \
  SUPERVISOR_HUNG_TURN_SECS=99999 bash "$BIN_DIR/watchdog.sh" "$SLUG" >/dev/null 2>&1 &
WD=$!
sleep 9
[ -d "$IDIR" ] && tmux has-session -t "$SESSION" 2>/dev/null \
  && ok "the run and its session are still there" || bad "the idle teardown took a chat waiting on his permission"
grep -q "full teardown" "$WDLOG" && bad "the watchdog logged a teardown" || ok "and nothing tried to tear it down"
[ -e "$IDIR/stalled.json" ] && bad "a dialog waiting for him was marked stalled" || ok "nor was it marked stalled"

echo "===== the control: answered, the same idle run goes as before ====="
# Answering moves the conversation on; the watchdog's own check then forgets the dialog.
printf '{"type":"user","message":{"content":"allowed"}}\n' >> "$TX"
for i in $(seq 1 20); do [ -d "$IDIR" ] || break; sleep 1; done
[ ! -d "$IDIR" ] && grep -q "full teardown" "$WDLOG" \
  && ok "torn down once nothing waits for him" || bad "the ordinary idle teardown no longer happens (log: $(tail -3 "$WDLOG" | tr '\n' ' '))"
kill "$WD" 2>/dev/null; wait "$WD" 2>/dev/null; WD=""

echo
[ "$fails" -eq 0 ] && echo "✅ permission teardown: all checks pass" || echo "❌ permission teardown: $fails failed"
[ "$fails" -eq 0 ]
