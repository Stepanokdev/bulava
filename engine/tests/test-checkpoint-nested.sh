#!/bin/bash
# A nested repository with no commits must not stop a night.
#
# He connected a folder holding three sub-projects, one of them a git repo with nothing committed
# yet. `git add -A` fails outright on that — "does not have a commit checked out" — so the
# checkpoint aborted, and the app reported only the path. Four times in a minute.
set -u
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
TMP="$(mktemp -d)"
mkdir -p "$TMP/tmux"
# A named socket, and isolation before the trap: a homeless `tmux_cleanup` here once took down
# the director's own session.
tmux_isolate "$TMP/tmux"
trap 'tmux_cleanup; rm -rf "$TMP"' EXIT INT TERM
# The app bridge must not leak in from the surrounding shell.
#
# These variables are how Bulava tells the engine "this run is a direct chat". A test that starts a
# run and then asserts terminal semantics has to actually BE a terminal start — and when the test
# is run from inside a Bulava chat, as it is whenever an agent runs it, both variables are already
# exported and the assertion measured the environment instead of the product. It failed for months
# for a reason that had nothing to do with the code under test.
unset SUPERVISOR_CHAT_CONTEXT_FILE SUPERVISOR_EXTRA_DIRS_FILE
tmux_isolate "$TMP/tmux"
export SUPERVISOR_CLAUDE_CMD="cat"
export SUPERVISOR_HANDSHAKE_WAIT=0
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
PROJ="$TMP/project"; mkdir -p "$PROJ/inner" "$PROJ/src"
echo "hello" > "$PROJ/src/main.txt"
( cd "$PROJ" && git init -q )
( cd "$PROJ/inner" && git init -q )            # a repo with NO commits — the whole point

echo "===== the checkpoint goes through, and says what it left out ====="
out="$(cd "$PROJ" && SUPERVISOR_NO_ATTACH=1 bash "$BIN_DIR/night-shift.sh" start "$PROJ" --no-attach 2>&1)"
case "$out" in *"checkpoint (initial) не вдався"*) bad "the checkpoint still aborts on a nested repo" ;;
  *) ok "the run was not refused" ;; esac
case "$out" in *"вкладені репозиторії без комітів"*) ok "it says which folders it left out" ;;
  *) bad "it excluded something silently" ;; esac

if ( cd "$PROJ" && git rev-parse HEAD >/dev/null 2>&1 ); then
  ok "the initial checkpoint exists — the run has git insurance"
else
  bad "no commit was made, so the run would have no way back"
fi

# The nested repo is EXCLUDED, not swallowed: nothing of its content is in our history.
if ( cd "$PROJ" && git ls-files | grep -q '^inner/' ); then
  bad "the nested repository's files were committed into this repo"
else
  ok "the nested repository stayed out of our history"
fi
if ( cd "$PROJ" && grep -q 'inner/' .git/info/exclude 2>/dev/null ); then
  ok "and it is on record in .git/info/exclude"
else
  bad "nothing records why it was skipped"
fi
# The real work is still there.
if ( cd "$PROJ" && git ls-files | grep -q '^src/main.txt$' ); then ok "the project's own files were committed"
else bad "the project's files were not committed"; fi

bash "$BIN_DIR/night-shift.sh" stop "$PROJ" >/dev/null 2>&1 || true
echo
[ "$fails" = 0 ] && echo "✅ checkpoint: a nested repo does not stop the night" || echo "❌ checkpoint: $fails problem(s)"
exit "$fails"
