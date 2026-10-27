#!/bin/bash
# A folder with no git of its own and exactly one repository inside is a project, not a workspace.
#
# 27 Oct: the director's game folder — the spec, `artifacts/`, an unpacked dependency and one
# repository, `bulava-world`, where the code lives. Every message to its chat came back «У цій теці
# 1 репозиторій… Підключи кожен репозиторій окремо», on the phone with nothing to press. Connecting
# the repository alone would cut the chat off from the spec beside it. The start asks about git
# instead (76, a button), and once he agrees the repository stays out of the outer history and is
# measured for the review as a repository of its own.
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
unset SUPERVISOR_CHAT_CONTEXT_FILE SUPERVISOR_EXTRA_DIRS_FILE
export SUPERVISOR_CLAUDE_CMD="cat"
export SUPERVISOR_HANDSHAKE_WAIT=0
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
export HOME="$TMP/home"; mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

start() { SUPERVISOR_NO_ATTACH=1 bash "$BIN_DIR/night-shift.sh" start "$1" --no-attach 2>&1; }

GAME="$TMP/game"
mkdir -p "$GAME/world/src" "$GAME/arceus/config" "$GAME/artifacts"
echo "the spec" > "$GAME/SPEC.md"
echo "dep" > "$GAME/arceus/config/a.yml"
echo "artifacts/" > "$GAME/.gitignore"
( cd "$GAME/world" && git init -q && echo "code" > src/main.js && git add -A \
  && git -c user.email=t@t -c user.name=t commit -qm init )
WORLD_HEAD="$(git -C "$GAME/world" rev-parse HEAD)"
GAME_C="$(cd "$GAME" && pwd -P)"

echo "===== the folder is not a workspace ====="
scan="$(bash "$BIN_DIR/night-shift.sh" scan-folder "$GAME")"
printf '%s\n' "$scan" | grep -qx "kind=plain" && ok "scan-folder: an ordinary folder, the app does not split it" \
  || bad "scan-folder says: $(printf '%s' "$scan" | head -1)"

# What a chat he is sitting at does: Bulava runs a folder with no committed git as a plain folder
# (`SUPERVISOR_PLAIN_FOLDER=1`, AppModel+DirectChat `runPlain`). The workspace refusal stood in
# front of that too — this is the start his message from the phone was making.
echo "===== the attended chat's start: a plain folder, no question, no git ====="
out="$(SUPERVISOR_PLAIN_FOLDER=1 start "$GAME")"; rc=$?
[ "$rc" = 0 ] && ok "the chat's start goes through (exit 0)" || bad "exit $rc: $(printf '%s' "$out" | head -3)"
[ -e "$GAME/.git" ] && bad "a plain-folder start made git" || ok "and makes no git"
[ "$(git -C "$GAME/world" rev-parse HEAD)" = "$WORLD_HEAD" ] && ok "the nested repository is untouched" \
  || bad "the nested repository changed"
bash "$BIN_DIR/night-shift.sh" stop "$GAME" >/dev/null 2>&1 || true

echo "===== unasked, it asks about git — it does not refuse the folder ====="
out="$(start "$GAME")"; rc=$?
[ "$rc" = 76 ] && ok "the git question (exit 76)" || bad "exit $rc: $(printf '%s' "$out" | head -3)"
case "$out" in *"робоча тека, а не репозиторій"*) bad "still refused as a workspace" ;; *) ok "no workspace refusal" ;; esac
[ -e "$GAME/.git" ] && bad "git was made before he agreed" || ok "nothing was created unasked"

echo "===== agreed, the start goes through and the repository stays its own ====="
out="$(bash "$BIN_DIR/night-shift.sh" allow-git "$GAME" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "allow-git accepts the folder" || bad "allow-git: exit $rc: $out"
out="$(start "$GAME")"; rc=$?
[ "$rc" = 0 ] && ok "the run started" || bad "exit $rc: $(printf '%s' "$out" | tail -5)"
if ( cd "$GAME" && git rev-parse -q --verify HEAD >/dev/null 2>&1 ); then ok "the first checkpoint exists"
else bad "no checkpoint commit"; fi
[ -z "$(git -C "$GAME" ls-files -s | awk '$1 == "160000"')" ] && ok "no gitlink in the outer commit" \
  || bad "the nested repository was committed as a gitlink"
git -C "$GAME" ls-files | grep -q '^world' && bad "files of the nested repository were committed" \
  || ok "nothing of the nested repository is in the outer history"
git -C "$GAME" ls-files | grep -qx 'SPEC.md' && ok "the folder's own files were committed" \
  || bad "SPEC.md is not in the checkpoint"
grep -qx '/world/' "$GAME/.git/info/exclude" && ok "left out by .git/info/exclude" || bad "no exclude rule"
[ "$(cat "$GAME/.gitignore")" = "artifacts/" ] && ok "his .gitignore is untouched" || bad ".gitignore was edited"
[ "$(git -C "$GAME/world" rev-parse HEAD)" = "$WORLD_HEAD" ] && [ -z "$(git -C "$GAME/world" status --porcelain)" ] \
  && ok "the nested repository's history and tree are unchanged" || bad "the nested repository was changed"
IDIR="$(ls -d "$SUPERVISOR_STATE_DIR"/instances/*/ 2>/dev/null | head -1)"
grep -q "^$GAME_C/world"$'\037' "${IDIR}extra-repos" 2>/dev/null \
  && ok "the review measures it as a repository of its own" || bad "the nested repository is invisible to the review"
bash "$BIN_DIR/night-shift.sh" stop "$GAME" >/dev/null 2>&1 || true

echo "===== the next start is an ordinary repository start ====="
out="$(start "$GAME")"; rc=$?
[ "$rc" = 0 ] && ok "started again" || bad "exit $rc: $(printf '%s' "$out" | tail -5)"
bash "$BIN_DIR/night-shift.sh" stop "$GAME" >/dev/null 2>&1 || true

echo "===== a nested repository his .gitignore hides is still measured ====="
HID="$TMP/hidden"; mkdir -p "$HID/lib [v2]"
echo "the spec" > "$HID/SPEC.md"
printf 'lib*/\n' > "$HID/.gitignore"
( cd "$HID/lib [v2]" && git init -q && echo "code" > main.js && git add -A \
  && git -c user.email=t@t -c user.name=t commit -qm init )
HID_C="$(cd "$HID" && pwd -P)"
bash "$BIN_DIR/night-shift.sh" allow-git "$HID" >/dev/null 2>&1
out="$(start "$HID")"; rc=$?
[ "$rc" = 0 ] && ok "the run started" || bad "exit $rc: $(printf '%s' "$out" | tail -5)"
git -C "$HID" ls-files | grep -q '^lib' && bad "the hidden repository reached the outer history" \
  || ok "the hidden repository stays outside the outer checkpoint"
[ -z "$(git -C "$HID" ls-files -s | awk '$1 == "160000"')" ] && ok "no gitlink" || bad "a gitlink was committed"
HIDIR="$(grep -l "$HID_C" "$SUPERVISOR_STATE_DIR"/instances/*/project-dir 2>/dev/null | head -1)"
HIDIR="${HIDIR%/project-dir}"
[ -n "$HIDIR" ] || HIDIR="$(ls -td "$SUPERVISOR_STATE_DIR"/instances/*/ | head -1)"
HIDIR="${HIDIR%/}"
grep -qF "$HID_C/lib [v2]"$'\037' "$HIDIR/extra-repos" 2>/dev/null \
  && ok "it is measured as a repository of its own" || bad "the hidden repository is not in extra-repos"
changed="$(bash -c '. "$1/supervisor-lib.sh" >/dev/null 2>&1; extra_repos_changed "$2"' _ "$BIN_DIR" "$HIDIR")"
[ -z "$changed" ] && ok "untouched, it reports no work" || bad "reports work before any change: $changed"
echo "changed" >> "$HID/lib [v2]/main.js"
changed="$(bash -c '. "$1/supervisor-lib.sh" >/dev/null 2>&1; extra_repos_changed "$2"' _ "$BIN_DIR" "$HIDIR")"
case "$changed" in *"lib [v2]"*) ok "a change inside it reaches the review" ;;
  *) bad "the change inside the hidden repository is invisible: '$changed'" ;; esac
bash "$BIN_DIR/night-shift.sh" stop "$HID" >/dev/null 2>&1 || true

echo "===== two repositories are still a workspace ====="
TWO="$TMP/two"
for r in a b; do mkdir -p "$TWO/$r" && ( cd "$TWO/$r" && git init -q && echo x > f && git add -A \
  && git -c user.email=t@t -c user.name=t commit -qm init ); done
out="$(start "$TWO")"
case "$out" in *"робоча тека, а не репозиторій"*) ok "refused as a workspace" ;; *) bad "not refused: $(printf '%s' "$out" | head -2)" ;; esac
[ -e "$TWO/.git" ] && bad "git was made over two repositories" || ok "nothing created"

echo "===== one repository, but the folder was not seen whole, is still refused ====="
DEEP="$TMP/deep"; mkdir -p "$DEEP/r" "$DEEP/a/b/c"
( cd "$DEEP/r" && git init -q && echo x > f && git add -A && git -c user.email=t@t -c user.name=t commit -qm init )
echo x > "$DEEP/a/b/c/f"
out="$(SUPERVISOR_WORKSPACE_SCAN_DEPTH=2 start "$DEEP")"; rc=$?
[ "$rc" != 0 ] && [ "$rc" != 76 ] && ok "refused (exit $rc)" || bad "exit $rc: $(printf '%s' "$out" | head -2)"
[ -e "$DEEP/.git" ] && bad "git was made over a folder it did not see whole" || ok "nothing created"

echo
[ "$fails" = 0 ] && echo "✅ one nested repository: a project that asks about git" || echo "❌ one nested repository: $fails problem(s)"
[ "$fails" = 0 ]
