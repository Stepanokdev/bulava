#!/bin/bash
# A screen Claude asks on at start is put in front of a person, not timed out.
#
# 5 Oct, a user's start: Claude Code opened on its own question — allow the external imports a
# CLAUDE.md asks for? — with "Enter to confirm · Esc to cancel" under it. No hook runs past such a
# screen, the engine knew four screens by name and this was not one of them, so after twelve seconds
# the start was rolled back and the session killed with the question still on it. Nobody could have
# answered it: it was in a detached pane, and then it was gone.
#
# Pinned here: any screen that asks — read off the key hints it prints, not off its wording — keeps
# the start waiting for an answer (and says so in the run's folder, where Bulava looks); an answer
# lets the start carry on; no answer ends it with the cause named; an automation's run, which has
# nobody to answer, does not wait at all.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$ROOT/bin"
unset SUPERVISOR_CHAT_CONTEXT_FILE SUPERVISOR_EXTRA_DIRS_FILE SUPERVISOR_CLAUDE_CMD SUPERVISOR_UNATTENDED
unset SUPERVISOR_REQUIRE_HANDSHAKE SUPERVISOR_HANDSHAKE_WAIT SUPERVISOR_SCREEN_ANSWER_WAIT
export SUPERVISOR_STATE_DIR="$(mktemp -d)"
. "$BIN_DIR/supervisor-lib.sh"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [$2]"; fi; }

TMP="$(mktemp -d)"
PROJ="$TMP/imports"
mkdir -p "$PROJ"
( cd "$PROJ" && git init -q && git config user.email t@t && git config user.name t \
    && echo x > f.txt && git add -A && git commit -qm init >/dev/null )
SLUG="$(slug_for "$PROJ")"
SES="$(session_name "$SLUG")"
IDIR="$(instance_dir "$SLUG")"
cleanup() {
  tmux kill-session -t "$SES" 2>/dev/null || true
  tmux_cleanup
  rm -rf "$SUPERVISOR_STATE_DIR" "$TMP"
}
trap cleanup EXIT

# The screen from the report, as Claude Code draws it.
IMPORTS='╭──────────────────────────────────────────────────────────────────────────╮
│ Allow external CLAUDE.md file imports?                                   │
│                                                                          │
│ This project'"'"'s CLAUDE.md imports files outside the current working      │
│ directory. Never allow this for third-party repositories.                │
│                                                                          │
│ External imports:                                                        │
│   /Users/someone/edx/green/devspace/idd/CLAUDE.md                        │
│                                                                          │
│ Important: Only use Claude Code with files you trust. Accessing untrusted│
│ files may pose security risks https://code.claude.com/docs/en/security   │
│                                                                          │
│ ❯ No, disable external imports                                           │
│   Yes, allow external imports                                            │
│                                                                          │
│ Enter to confirm · Esc to cancel                                         │
╰──────────────────────────────────────────────────────────────────────────╯'

echo "===== a screen that asks is told from one that does not ====="
check "the external-imports question asks" 'handshake_screen_asks "$IMPORTS"'
check "a numbered permission dialog asks" 'handshake_screen_asks " Do you want to proceed?
 ❯ 1. Yes
   2. No
 Esc to cancel · Tab to amend"'
check "a yes/no line asks" 'handshake_screen_asks "Overwrite settings? (y/n)"'
check "press-enter asks" 'handshake_screen_asks "Update installed. Press Enter to continue…"'
check "the composer waiting for a message does not" '! handshake_screen_asks "──────────
❯
──────────
  ? for shortcuts"'
check "a turn running does not" '! handshake_screen_asks "✻ Thinking… (12s · esc to interrupt)"'
check "words like it far up the conversation do not" '! handshake_screen_asks "the agent wrote: press Enter to continue
1
2
3
4
5
6
7
8
9
10
11
──────────
❯
──────────"'
check "and the four screens known by name keep their names" \
      '[ "$(handshake_screen " Is this a project you created or one you trust?
 ❯ 1. Yes, proceed
 Enter to confirm · Esc to cancel")" = trust ]'

# A worker that shows the screen, waits for one key the way Claude does, and — if that key is Enter
# — goes on to start, which is when the SessionStart hook would confirm the run-id.
tmux_isolate "$TMP/tmux"
STUB="$TMP/asking-claude.sh"
{
  printf '%s\n' '#!/bin/bash'
  printf 'cat <<'"'"'SCREEN'"'"'\n%s\nSCREEN\n' "$IMPORTS"
  printf '%s\n' 'IFS= read -rsn1 key'
  printf '%s\n' '[ -z "$key" ] || exit 0'
  printf '%s\n' "touch $(printf '%q' "$IDIR")/handshake-ok"
  printf '%s\n' 'echo "external imports: disabled"'
  printf '%s\n' 'sleep 120'
} > "$STUB"
chmod +x "$STUB"

start_in_background() {  # extra env as arguments
  ( cd "$PROJ" && env "$@" SUPERVISOR_CLAUDE_CMD="$STUB" SUPERVISOR_NO_ATTACH=1 SUPERVISOR_HANDSHAKE_WAIT=3 \
      bash "$BIN_DIR/night-shift.sh" start "$PROJ" --no-attach > "$TMP/out" 2>&1; echo "$?" > "$TMP/rc" ) &
}
wait_for() {  # $1 = seconds  $2 = condition
  local n=0
  while [ "$n" -lt $(( $1 * 4 )) ]; do eval "$2" && return 0; sleep 0.25; n=$((n + 1)); done
  return 1
}

echo "===== answered: the start waits for the person, then carries on ====="
rm -f "$TMP/rc"
start_in_background SUPERVISOR_SCREEN_ANSWER_WAIT=60
check "the run's folder says a screen is waiting for an answer" 'wait_for 15 "[ -f \"\$IDIR/screen-wait.json\" ]"'
check "with when it began" 'jq -e ".at > 0 and .stage == \"start\"" "$IDIR/screen-wait.json" >/dev/null'
sleep 5
check "well past the three seconds a start used to get, it has not been rolled back" \
      '[ ! -f "$TMP/rc" ] && tmux has-session -t "$SES" 2>/dev/null'
# What Bulava does with the person's choice: the selection is already on «No», so Enter.
tmux send-keys -t "$SES" Enter
check "the start finishes once it is answered" 'wait_for 20 "[ -f \"\$TMP/rc\" ]"'
check "and succeeds" '[ "$(cat "$TMP/rc" 2>/dev/null)" = 0 ]'
check "the waiting marker is gone" '[ ! -f "$IDIR/screen-wait.json" ]'
check "the session goes on" 'tmux has-session -t "$SES" 2>/dev/null'
check "the log says what happened" 'grep -q "asking on its own screen at start" "$SUPERVISOR_STATE_DIR/supervisor.log" && grep -q "the screen was answered" "$SUPERVISOR_STATE_DIR/supervisor.log"'
tmux kill-session -t "$SES" 2>/dev/null
for f in "$IDIR"/watchdog.pid; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; done
rm -rf "$IDIR"; rm -f "$SUPERVISOR_STATE_DIR/night-mode"

echo "===== not answered: the start ends, and says it was waiting on a screen ====="
rm -f "$TMP/rc"
start_in_background SUPERVISOR_SCREEN_ANSWER_WAIT=4
check "it ends" 'wait_for 30 "[ -f \"\$TMP/rc\" ]"'
check "refused" '[ "$(cat "$TMP/rc" 2>/dev/null)" != 0 ]'
check "the cause is the screen" 'grep -q "^handshake-blocked=screen$" "$TMP/out"'
check "said in words" 'grep -q "питав щось на своєму екрані" "$TMP/out"'
check "with what the screen showed" 'grep -q "Enter to confirm" "$TMP/out"'
check "nothing left running" '! tmux has-session -t "$SES" 2>/dev/null'

echo "===== an automation's run has nobody to answer, and does not wait ====="
rm -f "$TMP/rc"
started=$(date +%s)
start_in_background SUPERVISOR_SCREEN_ANSWER_WAIT=60 SUPERVISOR_UNATTENDED=1
check "it ends" 'wait_for 30 "[ -f \"\$TMP/rc\" ]"'
check "within the ordinary few seconds, not the minute a person would get" '[ $(( $(date +%s) - started )) -lt 20 ]'
check "refused, naming the screen" '[ "$(cat "$TMP/rc" 2>/dev/null)" != 0 ] && grep -q "^handshake-blocked=screen$" "$TMP/out"'

echo
[ "$fails" -eq 0 ] && echo "✅ a screen at start: all checks pass" || echo "❌ a screen at start: $fails failed"
[ "$fails" -eq 0 ]
