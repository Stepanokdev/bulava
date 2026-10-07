#!/bin/bash
# `night-shift commit-preview`: what «Commit as me» would commit, read without committing.
#
# Bulava shows its diff to a model to name the commit and point at anything that should stay out.
# So two things matter more than the diff itself: a file that looks like a key means NO diff at all
# (a key must not reach a model on its way to being refused), and reading it changes nothing — not
# HEAD, not what the director staged, not the files.
set -u
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
export HOME="$TMP/home"; mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset SUPERVISOR_CHAT_CONTEXT_FILE SUPERVISOR_EXTRA_DIRS_FILE

P="$TMP/project with space"; mkdir -p "$P/src"
( cd "$P" && git init -q && git config user.name "The Director" && git config user.email d@example.com \
  && echo one > src/a.txt && git add -A && git commit -qm "Add a" )
echo two >> "$P/src/a.txt"
echo new > "$P/src/b.txt"
( cd "$P" && git add src/b.txt )          # a staged split the preview must not disturb
mkdir -p "$P/inner" && ( cd "$P/inner" && git init -q && echo x > x && git add x \
  && git -c user.name=i -c user.email=i@i commit -qm x )

state() { ( cd "$P" && git rev-parse HEAD; git diff --cached --name-only; git diff --name-only; git status --porcelain ) | shasum; }
before="$(state)"

echo "===== a clean change: the diff, the count, the repository's own subjects ====="
out="$(bash "$BIN_DIR/night-shift.sh" commit-preview "$P" 2>&1)"
echo "$out" | jq -e . >/dev/null 2>&1 && ok "it answers in JSON" || bad "not JSON: $out"
[ "$(echo "$out" | jq -r .scan)" = ok ] && ok "the scan ran" || bad "scan: $(echo "$out" | jq -r .scan)"
[ "$(echo "$out" | jq -r '.secrets | length')" = 0 ] && ok "nothing looks like a key" || bad "secrets: $out"
echo "$out" | jq -r .diff | grep -q '^+two' && ok "the unstaged edit is in the diff" || bad "missing the edit"
echo "$out" | jq -r .diff | grep -q 'src/b.txt' && ok "the staged new file is in it" || bad "missing the staged file"
echo "$out" | jq -r .diff | grep -q 'inner/x' && bad "a nested repository's files leaked in" || ok "the nested repository stays out"
[ "$(echo "$out" | jq -r '.recent[0]')" = "Add a" ] && ok "recent subjects come with it" || bad "recent: $(echo "$out" | jq -c .recent)"
[ "$(echo "$out" | jq -r .digest)" = "$(cd "$P" && bash -c ". '$BIN_DIR/supervisor-lib.sh' >/dev/null 2>&1; dirty_digest '$P'")" ] \
  && ok "the digest is the one the commit will be checked against" || bad "digest differs"
[ "$(state)" = "$before" ] && ok "reading it changed nothing" || bad "the preview moved HEAD, the index or the files"

echo "===== a key in the change: no diff at all ====="
printf 'AKIA%s\n' "ABCDEFGHIJKLMNOP" > "$P/src/aws.txt"
out="$(bash "$BIN_DIR/night-shift.sh" commit-preview "$P" 2>&1)"
echo "$out" | jq -r '.secrets[]' | grep -qx 'src/aws.txt' && ok "the file is named" || bad "secrets: $(echo "$out" | jq -c .secrets)"
[ -z "$(echo "$out" | jq -r .diff)" ] && ok "and not a byte of the diff is handed out" || bad "a diff came with a key in it"
rm -f "$P/src/aws.txt"

echo "===== not a repository ====="
mkdir -p "$TMP/plain"
[ "$(bash "$BIN_DIR/night-shift.sh" commit-preview "$TMP/plain" | jq -r .error)" = no-repo ] \
  && ok "says so" || bad "no-repo not reported"

echo
[ "$fails" = 0 ] && { echo "OK"; exit 0; } || { echo "$fails failed"; exit 1; }
