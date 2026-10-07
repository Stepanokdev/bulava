#!/bin/bash
# A start nobody confirmed says WHY, from what the worker's screen showed.
#
# 24 Sep, a new user's first chat: «хуки не підтвердили run-id за 12s … Перевір встановлення
# хуків: bash install.sh», and the start was rolled back. The hooks were not the problem. A Claude
# Code that has never been run interactively opens on its theme picker, and runs no SessionStart
# hook until that is answered — in a detached tmux pane nobody can see. The only advice on offer
# sent him to reinstall something that was fine, and the rollback killed the one witness.
#
# Pinned here: each screen Claude can stop on is named, a missing or broken hook install is told
# apart from all of them, and what the pane showed survives the rollback in the log.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$ROOT/bin"
unset SUPERVISOR_CHAT_CONTEXT_FILE SUPERVISOR_EXTRA_DIRS_FILE SUPERVISOR_CLAUDE_CMD
unset SUPERVISOR_REQUIRE_HANDSHAKE SUPERVISOR_HANDSHAKE_WAIT
export SUPERVISOR_STATE_DIR="$(mktemp -d)"
. "$BIN_DIR/supervisor-lib.sh"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [$2]"; fi; }

TMP="$(mktemp -d)"
PROJ="$TMP/first-run"
mkdir -p "$PROJ"
( cd "$PROJ" && git init -q && git config user.email t@t && git config user.name t \
    && echo x > f.txt && git add -A && git commit -qm init >/dev/null )
SES="$(session_name "$(slug_for "$PROJ")")"
cleanup() {
  tmux kill-session -t "$SES" 2>/dev/null || true
  tmux_cleanup
  rm -rf "$SUPERVISOR_STATE_DIR" "$TMP"
}
trap cleanup EXIT

echo "===== the screen Claude stopped on is named ====="
# Real text from Claude Code 2.1.281's own screens, not paraphrases of them.
check "the first-run theme picker is onboarding" \
      '[ "$(handshake_blocker "Welcome to Claude Code
 Let'"'"'s get started.
 Choose the text style that looks best with your terminal")" = onboarding ]'
check "a login prompt is login" \
      '[ "$(handshake_blocker " Select login method:")" = login ]'
check "the folder-trust question is trust" \
      '[ "$(handshake_blocker " Quick safety check: Is this a project you created or one you trust?
 ❯ No, exit
   Yes, I trust this folder")" = trust ]'

echo "===== the hooks are suspected only when no screen explains it ====="
HOOK="$TMP/engine/hooks/safety-check.sh"
mkdir -p "$(dirname "$HOOK")"; : > "$HOOK"
ws() { printf '%s' "$1" > "$SUPERVISOR_STATE_DIR/worker-settings.json"; }
rm -f "$SUPERVISOR_STATE_DIR/worker-settings.json"
check "no worker settings at all is hooks" '[ "$(handshake_blocker "")" = hooks ]'
ws '{"hooks":{"PreToolUse":[]}}'
check "settings without the SessionStart hook is hooks" '[ "$(handshake_blocker "")" = hooks ]'
ws "{\"hooks\":{\"SessionStart\":[{\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"'$TMP/gone/safety-check.sh'\"}]}]}}"
check "a hook pointing at a file that is not there is hooks" '[ "$(handshake_blocker "")" = hooks ]'
# Quoted the way install.sh writes it (shlex.quote), because the real path has a space in it.
ws "{\"hooks\":{\"SessionStart\":[{\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"'$HOOK'\"}]}]}}"
check "an installed hook with no session to look at is exited" \
      '[ "$(handshake_blocker "" "no-such-slug-$$")" = exited ]'
check "an installed hook and a quiet pane is unknown, not hooks" '[ "$(handshake_blocker "")" = unknown ]'
check "a screen outranks a broken install" \
      'rm -f "$SUPERVISOR_STATE_DIR/worker-settings.json"; [ "$(handshake_blocker "Choose the text style")" = onboarding ]'

echo "===== end to end: a worker sitting on the theme picker ====="
# The launcher for real, the worker stubbed to show what a fresh Claude shows and then wait —
# which is all a fresh Claude does.
tmux_isolate "$TMP/tmux"
STUB="$TMP/fresh-claude.sh"
printf '%s\n' '#!/bin/bash' 'printf "Welcome to Claude Code\n Let'"'"'s get started.\n Choose the text style that looks best with your terminal\n"' 'sleep 60' > "$STUB"
chmod +x "$STUB"
out="$(cd "$PROJ" && SUPERVISOR_CLAUDE_CMD="$STUB" SUPERVISOR_NO_ATTACH=1 SUPERVISOR_HANDSHAKE_WAIT=3 \
       bash "$BIN_DIR/night-shift.sh" start "$PROJ" --no-attach 2>&1)"; rc=$?
check "the start is still refused"                 '[ "$rc" != 0 ]'
check "and still says there was no confirmation"   'printf "%s" "$out" | grep -q "підтвердження нема"'
check "the cause is given for the app to read"     'printf "%s" "$out" | grep -q "^handshake-blocked=onboarding$"'
check "and in words, pointing at the theme"        'printf "%s" "$out" | grep -q "вибору теми"'
check "it no longer sends anyone to reinstall hooks" '! printf "%s" "$out" | grep -q "install.sh"'
check "the log keeps what the pane showed"         'grep -q "│ .*Choose the text style" "$SUPERVISOR_STATE_DIR/supervisor.log"'
check "and nothing is left running"                '! tmux has-session -t "$SES" 2>/dev/null'

echo
[ "$fails" -eq 0 ] && echo "✅ handshake blocker: all checks pass" || echo "❌ handshake blocker: $fails failed"
[ "$fails" -eq 0 ]
