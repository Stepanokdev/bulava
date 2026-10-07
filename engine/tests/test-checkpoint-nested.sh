#!/bin/bash
# A nested repository with no commits must not stop a night — nor be committed into the director's.
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
export HOME="$TMP/home"; mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
PROJ="$TMP/project"; mkdir -p "$PROJ/inner" "$PROJ/src"
echo "hello" > "$PROJ/src/main.txt"
( cd "$PROJ" && git init -q && git config user.name "The Director" && git config user.email director@example.com )
( cd "$PROJ/inner" && git init -q )            # a repo with NO commits — the whole point

# The director's own repository with nothing committed yet. The first commit in it is theirs, so a
# start asks instead of making it — as `night-shift` it used to, silently.
echo "===== unasked, nothing is committed ====="
out="$(cd "$PROJ" && bash "$BIN_DIR/night-shift.sh" start "$PROJ" --no-attach 2>&1)"; rc=$?
[ "$rc" = 77 ] && ok "it asks (exit 77)" || bad "exit $rc: $out"
if ( cd "$PROJ" && git rev-parse -q --verify HEAD >/dev/null 2>&1 ); then bad "a commit was made unasked"
else ok "no commit was made"; fi

echo "===== answered, the commit goes through, and says what it left out ====="
out="$(cd "$PROJ" && bash "$BIN_DIR/night-shift.sh" start "$PROJ" --no-attach --dirty=commit --message="first" 2>&1)"; rc=$?
case "$out" in *"не вдався"*) bad "the commit still aborts on a nested repo: $out" ;;
  *) [ "$rc" = 0 ] && ok "the run was not refused" || bad "exit $rc: $out" ;; esac
case "$out" in *"Вкладені репозиторії"*"inner/"*) ok "it says which folders it left out" ;;
  *) bad "it excluded something silently: $out" ;; esac

if ( cd "$PROJ" && git rev-parse HEAD >/dev/null 2>&1 ); then
  ok "the first commit exists — the run has something to be measured against"
else
  bad "no commit was made, so the run would have no way back"
fi
[ "$(cd "$PROJ" && git log -1 --format='%ae')" = "director@example.com" ] && ok "and it is the director's, under their own name" \
  || bad "authored by $(cd "$PROJ" && git log -1 --format='%an <%ae>')"

# The nested repo is EXCLUDED, not swallowed: nothing of its content is in our history.
if ( cd "$PROJ" && git ls-files | grep -q '^inner' ); then
  bad "the nested repository was committed into this repo"
else
  ok "the nested repository stayed out of our history"
fi
if ( cd "$PROJ" && grep -q 'inner' .git/info/exclude 2>/dev/null ); then
  bad "the director's .git/info/exclude was edited to hide it"
else
  ok "and nothing was written into .git/info/exclude to do it"
fi
# The real work is still there.
if ( cd "$PROJ" && git ls-files | grep -q '^src/main.txt$' ); then ok "the project's own files were committed"
else bad "the project's files were not committed"; fi

bash "$BIN_DIR/night-shift.sh" stop "$PROJ" >/dev/null 2>&1 || true
echo
[ "$fails" = 0 ] && echo "✅ checkpoint: a nested repo does not stop the night" || echo "❌ checkpoint: $fails problem(s)"
exit "$fails"
