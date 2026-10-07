#!/bin/bash
# Live, against the real Claude Code CLI — not part of the suite: it needs `claude` on PATH and
# about half a minute. The real launcher starts the real CLI into a fresh git repository, twice:
#   1. with a Claude config that has never finished its first run → the theme picker;
#   2. with this machine's own config, in a folder nobody has trusted → the trust question.
# Each start must be refused and must name what the worker's real screen showed.
# A tmux server of its own: new sessions take the SERVER's environment, so on a shared server the
# fresh CLAUDE_CONFIG_DIR would never reach the worker — and nothing here may touch real sessions.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v claude >/dev/null || { echo "claude is not on PATH"; exit 1; }
T="$(mktemp -d)"
# Isolation first, the trap second — and the server goes only through tmux_cleanup, which kills
# nothing unless TMUX_TMPDIR is still the directory this script made.
tmux_isolate "$T/tmux"
trap 'tmux_cleanup; rm -rf "$T"' EXIT INT TERM
unset SUPERVISOR_CLAUDE_CMD SUPERVISOR_CHAT_CONTEXT_FILE SUPERVISOR_EXTRA_DIRS_FILE
fails=0

attempt() {  # $1 = label  $2 = expected cause  $3 = CLAUDE_CONFIG_DIR or empty for the real one
  local p="$T/probe-$2" out rc
  mkdir -p "$p"
  ( cd "$p" && git init -q && git config user.email t@t && git config user.name t \
      && echo x > f && git add -A && git commit -qm init >/dev/null )
  export SUPERVISOR_STATE_DIR="$T/state-$2"; mkdir -p "$SUPERVISOR_STATE_DIR"
  if [ -n "$3" ]; then mkdir -p "$3"; export CLAUDE_CONFIG_DIR="$3"; else unset CLAUDE_CONFIG_DIR; fi
  # A tmux server with nothing on it yet exits the moment it has no sessions; keep one open so
  # the launcher's session and this environment share a server.
  tmux new-session -d -s keepalive-$2 "sleep 120"
  out="$(cd "$p" && SUPERVISOR_NO_ATTACH=1 SUPERVISOR_HANDSHAKE_WAIT=12 \
         bash "$ROOT/bin/night-shift.sh" start "$p" --no-attach 2>&1)"; rc=$?
  tmux kill-session -t keepalive-$2 2>/dev/null
  if [ "$rc" != 0 ] && printf '%s\n' "$out" | grep -qx "handshake-blocked=$2"; then
    echo "  ✅ $1: refused, and named as $2"
  else
    echo "  ❌ $1: rc=$rc"; printf '%s\n' "$out" | tail -8 | sed 's/^/     /'; fails=$((fails + 1))
  fi
}

attempt "a Claude that never finished its first run" onboarding "$T/claude-config"
attempt "a folder this Claude has not been told to trust" trust ""
[ "$fails" -eq 0 ]
