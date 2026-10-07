#!/bin/bash
# A checkpoint too big because of a few files names those files, and leaving them out is one answer.
#
# The director connected a folder that was not yet a repository, with a four-gigabyte screen
# recording lying in it untracked. The first checkpoint would have taken 3828 MB against a limit of
# 1024, so the start refused, removed the `.git` it had just made, and the chat showed a red
# paragraph about megabytes with nothing to press. Now the start stops with exit 79, writes down the
# biggest files (path, size, tracked or not), and `heavy-exclude` turns that list into ignore rules —
# escaped, anchored, kept outside the folder so they outlive the `.git` that was taken away, and
# written into the next one. A tracked file is explained, never untracked; no file is deleted.
set -u
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
TMP="$(mktemp -d)"
mkdir -p "$TMP/tmux"
tmux_isolate "$TMP/tmux"
trap 'tmux_cleanup; rm -rf "$TMP"' EXIT INT TERM
unset SUPERVISOR_CHAT_CONTEXT_FILE SUPERVISOR_EXTRA_DIRS_FILE SUPERVISOR_DIRTY SUPERVISOR_DIRTY_DIGEST SUPERVISOR_COMMIT_MESSAGE
unset SUPERVISOR_APP_ANSWERS SUPERVISOR_RUN_ENV_FROM_APP
export SUPERVISOR_CLAUDE_CMD="cat"
export SUPERVISOR_HANDSHAKE_WAIT=0
export SUPERVISOR_NO_SKILL_PICK=1
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
export HOME="$TMP/home"; mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
# The budget, scaled down: 2 MB for a checkpoint, 1.5 MB for one file. The files below are 3 MB and
# sparse — the sizes are what the check reads, and nothing has to be written to disk for them.
export SUPERVISOR_CHECKPOINT_MAX_BYTES=2097152
export SUPERVISOR_CHECKPOINT_MAX_FILE_BYTES=1572864
NS="$BIN_DIR/night-shift.sh"
APP=(env SUPERVISOR_RUN_ENV_FROM_APP=1 "SUPERVISOR_APP_ANSWERS=dirty mcp git heavy")

big() { mkdir -p "$(dirname "$1")"; rm -f "$1"; mkfile -n "${2:-3m}" "$1"; }
# Whether the rules leave this exact file out (as for a file not yet added), and whether it is
# tracked. Both take a NAME: in a pathspec `[final]` is a glob, and it would match the twin.
ignored() { git -C "$1" check-ignore -q --no-index -- "$2"; }
tracked() { GIT_LITERAL_PATHSPECS=1 git -C "$1" ls-files --error-unmatch -- "$2" >/dev/null 2>&1; }

REC='Screen Recording [final] #2.mov'      # brackets and a hash: a glob class and a comment sign
ODD='media/take *1*!.raw '                 # a star, a bang, and a trailing space
TWIN='Screen Recording f #2.mov'           # what `[final]` would match if it were left a glob

echo "===== a folder with no git and a 3 MB recording: the start asks, and names the files ====="
P="$TMP/videos"; mkdir -p "$P/src"
echo "hello" > "$P/src/app.txt"
big "$P/$REC"; big "$P/$ODD"; echo "small twin" > "$P/$TWIN"
bash "$NS" allow-git "$P" >/dev/null 2>&1 || bad "allow-git refused an ordinary folder"

out="$("${APP[@]}" bash "$NS" start "$P" --no-attach 2>&1)"; rc=$?
[ "$rc" = 79 ] && ok "it asks (exit 79)" || bad "exit $rc: $out"
[ -e "$P/.git" ] && bad "the .git it had just made was left behind" || ok "the .git it had just made was taken away"
case "$out" in *"night-shift "*|*"--dirty"*|*"heavy-exclude"*) bad "an app was handed terminal commands: $out" ;;
  *) ok "no terminal commands in what an app is told" ;; esac
case "$out" in *"мав би взяти"*"Screen Recording [final] #2.mov"*"Bulava запропонує"*) ok "it says what it would cost, which files, and that Bulava will offer" ;;
  *) bad "the message does not name the files: $out" ;; esac
[ -e "$P/$REC" ] && [ -e "$P/$ODD" ] && ok "every file is still on disk" || bad "a file is gone"

state="$(bash "$NS" heavy-state "$P" 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && ok "heavy-state answers" || bad "heavy-state exit $rc: $state"
n="$(printf '%s' "$state" | jq '.files | length')"
[ "$n" = 2 ] && ok "both big files are listed, and only they ($n)" || bad "listed $n: $state"
[ "$(printf '%s' "$state" | jq --arg p "$REC" '.files[] | select(.path == $p) | .size')" = 3145728 ] \
  && ok "with its size in bytes" || bad "no size for the recording: $state"
[ "$(printf '%s' "$state" | jq '[.files[] | select(.tracked)] | length')" = 0 ] \
  && ok "nothing is marked tracked in a folder that had no git" || bad "tracked flag wrong: $state"
[ "$(printf '%s' "$state" | jq --arg p "$REC" -r '.files[] | select(.path == $p) | .rule')" = '/Screen Recording \[final\] \#2.mov' ] \
  && ok "the rule is anchored and its brackets and hash are escaped" || bad "rule: $(printf '%s' "$state" | jq -r '.files[].rule')"
[ "$(printf '%s' "$state" | jq --arg p "$ODD" -r '.files[] | select(.path == $p) | .rule')" = '/media/take \*1\*\!.raw\ ' ] \
  && ok "a star, a bang and a trailing space are escaped too" || bad "rule: $(printf '%s' "$state" | jq -r '.files[].rule')"
[ "$(printf '%s' "$state" | jq '.fits_after')" = true ] && ok "and leaving them out would fit" || bad "fits_after: $state"
[ "$(printf '%s' "$state" | jq '.total_bytes > .limit_bytes')" = true ] && ok "the total and the limit are there" || bad "totals: $state"

out="$(bash "$NS" start "$P" --no-attach 2>&1)"; rc=$?
[ "$rc" = 79 ] && ok "a terminal is asked the same way (79)" || bad "terminal exit $rc"
case "$out" in *".gitignore"*) ok "and told how to do it by hand, in words" ;; *) bad "terminal text: $out" ;; esac

echo
echo "===== «leave them out»: the rule outlives the .git that was taken away ====="
sum="$(bash "$NS" heavy-exclude "$P" local 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "heavy-exclude local went through" || bad "heavy-exclude exit $rc: $sum"
[ "$(printf '%s' "$sum" | jq '.rules | length')" = 2 ] && ok "two rules written" || bad "summary: $sum"
[ -e "$P/.gitignore" ] && bad "the director's .gitignore was written without being asked" || ok "nothing written into the project"
[ -e "$P/.git" ] && bad "a .git appeared before any start" || ok "and no .git made by the answer itself"

out="$("${APP[@]}" bash "$NS" start "$P" --no-attach 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "the next start goes through" || bad "exit $rc: $out"
grep -qxF '/Screen Recording \[final\] \#2.mov' "$P/.git/info/exclude" 2>/dev/null \
  && ok "the new repository got the rule in .git/info/exclude" || bad "exclude: $(cat "$P/.git/info/exclude" 2>/dev/null)"
ignored "$P" "$REC" && ok "git ignores the recording" || bad "the recording is not ignored"
ignored "$P" "$ODD" && ok "git ignores the file with a star, a bang and a trailing space" || bad "the odd file is not ignored"
ignored "$P" "$TWIN" && bad "the rule matched another file — [final] was read as a glob" || ok "a file the glob would have matched is not ignored"
if tracked "$P" "$REC"; then bad "the recording went into the first commit"
else ok "the recording is not in the first commit"; fi
tracked "$P" src/app.txt && ok "the project's own files are" || bad "src/app.txt was not committed"
tracked "$P" "$TWIN" && ok "and so is the small twin" || bad "the twin was left out"
[ -e "$P/$REC" ] && [ -e "$P/$ODD" ] && ok "the big files are still on disk" || bad "a big file is gone"
bash "$NS" stop "$P" >/dev/null 2>&1 || true

echo
echo "===== the other answer: the same rules in the project's .gitignore ====="
G="$TMP/gi"; mkdir -p "$G"
echo "keep" > "$G/readme.txt"; printf 'node_modules/' > "$G/.gitignore"    # no trailing newline
big "$G/dump.bin"
bash "$NS" allow-git "$G" >/dev/null 2>&1
"${APP[@]}" bash "$NS" start "$G" --no-attach >/dev/null 2>&1; rc=$?
[ "$rc" = 79 ] && ok "it asks (79)" || bad "exit $rc"
bash "$NS" heavy-exclude "$G" gitignore >/dev/null 2>&1 && ok "heavy-exclude gitignore went through" || bad "heavy-exclude gitignore failed"
[ "$(cat "$G/.gitignore")" = "$(printf 'node_modules/\n/dump.bin')" ] && ok ".gitignore keeps its line and gets the new one on a line of its own" \
  || bad ".gitignore: $(cat "$G/.gitignore")"
[ -s "$(. "$BIN_DIR/supervisor-lib.sh"; checkpoint_excludes_file "$G")" ] && bad "the local record was written for a .gitignore answer" || ok "and nothing else"
"${APP[@]}" bash "$NS" start "$G" --no-attach >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "the next start goes through" || bad "exit $rc"
tracked "$G" .gitignore && ok ".gitignore is in the first commit" || bad ".gitignore was not committed"
tracked "$G" dump.bin && bad "dump.bin was committed" || ok "dump.bin is not"
bash "$NS" stop "$G" >/dev/null 2>&1 || true

echo
echo "===== a tracked file is explained, never untracked ====="
R="$TMP/repo"; mkdir -p "$R"
( cd "$R" && git init -q -b main && git config user.name "Ihor Director" && git config user.email ihor@example.com
  echo small > model.bin; echo code > main.c; git add . && git commit -qm base )
big "$R/model.bin"            # tracked, and now 3 MB
big "$R/capture.mov"          # untracked, 3 MB
out="$("${APP[@]}" bash "$NS" start "$R" --no-attach --dirty=keep 2>&1)"; rc=$?
[ "$rc" = 79 ] && ok "leaving changes in place, a too-big snapshot asks too (79)" || bad "exit $rc: $out"
[ -d "$R/.git" ] && ok "the director's own .git is left alone" || bad "the director's .git was removed"
state="$(bash "$NS" heavy-state "$R")"
[ "$(printf '%s' "$state" | jq '.files[] | select(.path == "model.bin") | .tracked')" = true ] && ok "model.bin is marked tracked" || bad "state: $state"
[ "$(printf '%s' "$state" | jq '.files[] | select(.path == "model.bin") | .rule')" = null ] && ok "and has no rule" || bad "a tracked file got a rule"
[ "$(printf '%s' "$state" | jq '.files[] | select(.path == "capture.mov") | .tracked')" = false ] && ok "capture.mov is not" || bad "state: $state"
[ "$(printf '%s' "$state" | jq '.fits_after')" = false ] && ok "and it says leaving out the untracked one will not be enough" || bad "fits_after: $state"
case "$out" in *"git уже відстежує"*"model.bin"*) ok "the message explains the tracked one" ;; *) bad "no explanation: $out" ;; esac

sum="$(bash "$NS" heavy-exclude "$R" local)"
[ "$(printf '%s' "$sum" | jq -c '.rules')" = '["/capture.mov"]' ] && ok "only the untracked file gets a rule" || bad "summary: $sum"
[ "$(printf '%s' "$sum" | jq -c '.tracked')" = '["model.bin"]' ] && ok "the tracked one is reported back" || bad "summary: $sum"
grep -qxF '/capture.mov' "$R/.git/info/exclude" && ok "written into the director's .git/info/exclude" || bad "exclude: $(cat "$R/.git/info/exclude")"
ignored "$R" capture.mov && ok "git ignores capture.mov" || bad "capture.mov not ignored"
tracked "$R" model.bin && ok "model.bin is still tracked" || bad "model.bin was untracked"
[ -z "$(git -C "$R" diff --cached --name-only)" ] && ok "nothing was staged" || bad "the index changed"
[ "$(git -C "$R" rev-list --count HEAD)" = 1 ] && ok "nothing was committed" || bad "a commit was made"
[ -e "$R/model.bin" ] && [ -e "$R/capture.mov" ] && ok "both files are still on disk" || bad "a file is gone"

out="$("${APP[@]}" bash "$NS" start "$R" --no-attach --dirty=keep 2>&1)"; rc=$?
[ "$rc" = 79 ] && ok "still too big because of the tracked file — asked again" || bad "exit $rc: $out"
state="$(bash "$NS" heavy-state "$R")"
[ "$(printf '%s' "$state" | jq -c '[.files[].path]')" = '["model.bin"]' ] && ok "and now only the tracked file is listed" || bad "state: $state"

echo
echo "===== «commit as me» with a big file in the list asks the same question ====="
K="$TMP/commit"; mkdir -p "$K"
( cd "$K" && git init -q -b main && git config user.name "Ihor Director" && git config user.email ihor@example.com
  echo code > main.c; git add . && git commit -qm base; echo more >> main.c )
big "$K/export.zip"
out="$("${APP[@]}" bash "$NS" start "$K" --no-attach --dirty=commit --message="wip" 2>&1)"; rc=$?
[ "$rc" = 79 ] && ok "asked (79), not refused" || bad "exit $rc: $out"
[ "$(git -C "$K" rev-list --count HEAD)" = 1 ] && ok "and nothing was committed" || bad "a commit was made"
[ "$(bash "$NS" heavy-state "$K" | jq -r '.files[0].path')" = export.zip ] && ok "the list names export.zip" || bad "state: $(bash "$NS" heavy-state "$K")"

echo
echo "===== too many files is not a list of big files ====="
C="$TMP/count"; mkdir -p "$C"; for i in $(seq 1 8); do echo x > "$C/f$i.txt"; done
bash "$NS" allow-git "$C" >/dev/null 2>&1
out="$(SUPERVISOR_CHECKPOINT_MAX_FILES=5 "${APP[@]}" bash "$NS" start "$C" --no-attach 2>&1)"; rc=$?
[ "$rc" = 1 ] && ok "a file-count overrun is still a refusal (exit 1)" || bad "exit $rc: $out"
case "$out" in *"мав би взяти 8 файлів"*) ok "and still says so" ;; *) bad "$out" ;; esac
[ -e "$C/.git" ] && bad "a half-made .git was left" || ok "and cleans up its .git"

echo
[ "$fails" = 0 ] && echo "✅ checkpoint overrun: the big files are named and can be left out" || { echo "❌ checkpoint overrun: $fails problem(s)"; exit 1; }
