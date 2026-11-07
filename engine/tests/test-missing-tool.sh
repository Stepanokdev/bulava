#!/bin/bash
# A Mac without tmux: the engine says so in a line the app reads, and touches nothing.
#
# 5 Nov, 1.17: a chat's first message met «❌ tmux не встановлено (brew install tmux)» from `start`.
# The refusal carried no marker, so the app took it for a broken start — it offered a repair, the
# repair spent two and a half minutes concluding that tmux was not installed, and the refusal reached
# us as an anonymous `chat.start_failed`. A missing tool is the director's to install, the same as a
# folder that is gone: `start-refused=tool:<name>` is how the app tells the two from a breakage.
#
# The engine is run on a PATH that has everything the machine has except tmux, so what is proven is
# the refusal itself, not a stub of it.
set -u
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
TMP="$(mktemp -d)"
mkdir -p "$TMP/tmux"
# Isolation BEFORE the trap: the start after the install below is real, and so is its tmux server.
tmux_isolate "$TMP/tmux"
trap 'tmux_cleanup; rm -rf "$TMP"' EXIT INT TERM
unset SUPERVISOR_CHAT_CONTEXT_FILE SUPERVISOR_EXTRA_DIRS_FILE TMUX
export SUPERVISOR_CLAUDE_CMD="cat"
export SUPERVISOR_HANDSHAKE_WAIT=0
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"

# Every command on this PATH, first one wins as it would, tmux left out.
NOTMUX="$TMP/bin"; mkdir -p "$NOTMUX"
IFS=: read -r -a _dirs <<< "$PATH"
for d in "${_dirs[@]}"; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    n="${f##*/}"
    [ "$n" = tmux ] && continue
    [ -x "$f" ] && [ ! -e "$NOTMUX/$n" ] && ln -s "$f" "$NOTMUX/$n"
  done
done
if PATH="$NOTMUX" command -v tmux >/dev/null 2>&1; then
  echo "❌ tmux is still on the test PATH — nothing below would prove anything"; exit 1
fi

PROJ="$TMP/project"
mkdir -p "$PROJ" && ( cd "$PROJ" && git init -q && echo hi > f.txt && git add -A \
  && git -c user.email=t@t -c user.name=t commit -qm init )

out="$(PATH="$NOTMUX" SUPERVISOR_NO_ATTACH=1 bash "$BIN_DIR/night-shift.sh" start "$PROJ" --no-attach 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok "start refuses without tmux (exit $rc)" || bad "start went on without tmux"
case "$out" in *"tmux не встановлено"*) ok "and says what is missing" ;;
  *) bad "no word about tmux — got: $(printf '%s' "$out" | head -2)" ;; esac
printf '%s\n' "$out" | grep -qx "start-refused=tool:tmux" \
  && ok "the refusal carries the marker the app reads as 'a tool to install'" \
  || bad "no start-refused=tool:tmux line — the app reports a Mac without tmux as a bug"
[ -z "$(ls -A "$SUPERVISOR_STATE_DIR/instances" 2>/dev/null)" ] \
  && ok "no run was left behind" || bad "a refused start left an instance behind"

for sub in revive resume; do
  out="$(PATH="$NOTMUX" SUPERVISOR_ENABLE_RESUME=1 bash "$BIN_DIR/night-shift.sh" $sub "$PROJ" sid-1 - --no-attach 2>&1)"; rc=$?
  { [ "$rc" != 0 ] && printf '%s\n' "$out" | grep -qx "start-refused=tool:tmux"; } \
    && ok "$sub says the same, in the same marker" \
    || bad "$sub without tmux: exit $rc, no marker — got: $(printf '%s' "$out" | head -2)"
done

# A message to a chat goes through worker-send, which reaches tmux before revive or resume do.
out="$(PATH="$NOTMUX" bash "$BIN_DIR/worker-send.sh" "$PROJ" sid-1 - - "hello" 2>&1)"; rc=$?
[ "$rc" = 1 ] && ok "a send refuses without tmux, before trying (exit 1)" || bad "a send without tmux: exit $rc"
printf '%s\n' "$out" | grep -qx "start-refused=tool:tmux" \
  && ok "and carries the marker" || bad "a send without tmux carries no marker — got: $(printf '%s' "$out" | head -3)"
printf '%s\n' "$out" | grep -q '^TIER=' && bad "it claims a tier for a message it never tried" \
                                        || ok "no tier: the message was never tried"
[ -z "$(ls -A "$SUPERVISOR_STATE_DIR/instances" 2>/dev/null)" ] \
  && ok "nothing was parked or created for it" || bad "a refused send left state behind"

# What the app's row leads to: Homebrew puts tmux on the PATH, and the same message, sent again,
# starts. The install is the one thing stood in for — tmux appears where `brew install` puts it.
REAL_TMUX="$(command -v tmux)"
ln -s "$REAL_TMUX" "$NOTMUX/tmux"
out="$(PATH="$NOTMUX" SUPERVISOR_NO_ATTACH=1 bash "$BIN_DIR/night-shift.sh" start "$PROJ" --no-attach 2>&1)"; rc=$?
printf '%s\n' "$out" | grep -q "^start-refused=" \
  && bad "after the install the start is still refused — got: $(printf '%s' "$out" | head -2)" \
  || ok "after the install the start is not refused"
[ "$rc" = 0 ] && ok "and it starts (exit 0)" || bad "the start after the install failed (exit $rc): $(printf '%s' "$out" | tail -3)"
_slug="$(ls "$SUPERVISOR_STATE_DIR/instances" 2>/dev/null | head -1)"
if [ -n "$_slug" ] && tmux list-sessions -F '#S' 2>/dev/null | grep -q .; then
  ok "its run and its tmux session are there ($_slug)"
else bad "no run or no tmux session after a start that said it started"; fi
PATH="$NOTMUX" bash "$BIN_DIR/night-shift.sh" stop "$PROJ" >/dev/null 2>&1 || true

echo
[ "$fails" = 0 ] && echo "✅ missing tool: refused in the app's words, nothing touched" \
                 || { echo "❌ missing tool: $fails failed"; exit 1; }
