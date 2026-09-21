#!/bin/bash
# The harness must not leave litter for the next worker to tidy.
#
# A client repo carried six AUDIT-*.md and a REVIEW-DEBT.md that runs months ago had written into
# it. They are untracked, so every new worker sees them; one tidied up by adding them to
# .gitignore, and the reviewer failed the run for "scope expansion outside the objective". A
# correct feature spent an extra round on litter the harness dropped itself.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
cleanup() {
  # These tests exercise launch bookkeeping, not Claude itself. Keep their tmux daemon private
  # and tear it down before deleting the fixture so no real worker survives the test run.
  tmux_cleanup
  rm -rf "$TMP"
}
trap cleanup EXIT
mkdir -p "$TMP/tmux"
unset TMUX
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
PROJ="$TMP/project"; mkdir -p "$PROJ/src"
echo "hello" > "$PROJ/src/main.txt"
( cd "$PROJ" && git init -q )
# What earlier runs left behind, plus a real project file that must be treated normally.
: > "$PROJ/AUDIT-20260623-1532.md"
: > "$PROJ/REVIEW-DEBT.md"
echo "notes" > "$PROJ/NOTES.md"

echo "===== a run starts, and the litter stops being the worker's problem ====="
out="$(cd "$PROJ" && SUPERVISOR_NO_ATTACH=1 bash "$BIN_DIR/night-shift.sh" start "$PROJ" --no-attach 2>&1)"
case "$out" in *"checkpoint"*"не вдався"*) bad "the run was refused: $out" ;; *) ok "the run started" ;; esac

if find "$SUPERVISOR_STATE_DIR/instances" -name direct-chat -print -quit 2>/dev/null | grep -q .; then
  bad "a terminal start inherited Bulava's direct-chat review mode"
else
  ok "a terminal start keeps console review semantics"
fi

if ( cd "$PROJ" && git status --short | grep -qE 'AUDIT-|REVIEW-DEBT'); then
  bad "the harness's own files are still untracked noise in the worktree"
else
  ok "they are out of sight — nothing for a worker to tidy"
fi

# Local only. A .gitignore change would land in the client's repository and in the diff the
# reviewer reads, which is the exact failure this prevents.
if ( cd "$PROJ" && git diff HEAD --name-only 2>/dev/null | grep -q '.gitignore' ) \
   || [ -f "$PROJ/.gitignore" ]; then
  bad "it wrote a tracked .gitignore instead of a local exclude"
else
  ok "the exclusion is local (.git/info/exclude), not a change to the repo"
fi

if ( cd "$PROJ" && grep -q 'REVIEW-DEBT.md' .git/info/exclude 2>/dev/null ); then
  ok "the exclude names them"
else
  bad "nothing was excluded"
fi

# The checkpoint must still contain the project's own files, litter aside.
if ( cd "$PROJ" && git ls-files | grep -q '^NOTES.md$' ); then
  ok "a real project file is committed as normal"
else
  bad "the exclusion swallowed a real file"
fi
if ( cd "$PROJ" && git ls-files | grep -qE 'AUDIT-|REVIEW-DEBT' ); then
  bad "the harness's files were committed into the client's history"
else
  ok "and none of the litter reached the history"
fi

echo
[ "$fails" -eq 0 ] && { echo "RESULT: passed"; exit 0; } || { echo "RESULT: $fails failed"; exit 1; }
