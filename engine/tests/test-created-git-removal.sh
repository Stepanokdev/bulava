#!/bin/bash
# A `.git` this start made and then took away must really be gone — or the director must be told it
# is not.
#
# Reported from 1.12 (chat.start_failed, twice): a checkpoint too big, the start said «Прибрав .git,
# який щойно створив», yet empty `hooks/ info/ objects/ refs/` stayed. Every start after that was
# refused as a broken repository, with no way out from the app. Here `rm` is made to leave exactly
# those empty directories behind.
set -u
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
TMP="$(mktemp -d)"; mkdir -p "$TMP/tmux"
tmux_isolate "$TMP/tmux"
trap 'tmux_cleanup; rm -rf "$TMP"' EXIT INT TERM
unset SUPERVISOR_CHAT_CONTEXT_FILE SUPERVISOR_EXTRA_DIRS_FILE SUPERVISOR_DIRTY SUPERVISOR_DIRTY_DIGEST SUPERVISOR_COMMIT_MESSAGE
unset SUPERVISOR_APP_ANSWERS SUPERVISOR_RUN_ENV_FROM_APP
export SUPERVISOR_CLAUDE_CMD="cat" SUPERVISOR_HANDSHAKE_WAIT=0 SUPERVISOR_NO_SKILL_PICK=1
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
export HOME="$TMP/home"; mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export SUPERVISOR_CHECKPOINT_MAX_BYTES=2097152 SUPERVISOR_CHECKPOINT_MAX_FILE_BYTES=1572864
NS="$BIN_DIR/night-shift.sh"
APP=(env SUPERVISOR_RUN_ENV_FROM_APP=1 "SUPERVISOR_APP_ANSWERS=dirty mcp git heavy")

# An `rm` that, for a `.git`, deletes every file and no directory, and fails — what was seen.
SHIM="$TMP/shim"; mkdir -p "$SHIM"
cat > "$SHIM/rm" <<'SH'
#!/bin/bash
for a in "$@"; do case "$a" in */.git) [ -n "${STUBBORN:-}" ] && { find "$a" ! -type d -delete; exit 1; } ;; esac; done
exec /bin/rm "$@"
SH
chmod +x "$SHIM/rm"

P="$TMP/videos"; mkdir -p "$P"; echo hi > "$P/a.txt"; mkfile -n 3m "$P/rec.mov"
bash "$NS" allow-git "$P" >/dev/null 2>&1 || bad "allow-git refused"

echo "===== removal keeps failing: the start says so instead of claiming it is gone ====="
out="$(STUBBORN=1 PATH="$SHIM:$PATH" "${APP[@]}" bash "$NS" start "$P" --no-attach 2>&1)"; rc=$?
[ "$rc" = 79 ] && ok "it asks about the heavy files (79)" || bad "exit $rc: $out"
case "$out" in *"Прибрав .git"*) bad "claimed the .git was removed: $out" ;; *) ok "no false claim of removal" ;; esac
case "$out" in *"Не зміг до кінця прибрати .git"*) ok "and says what is left" ;; *) bad "silent about the leftover: $out" ;; esac
[ -d "$P/.git/objects" ] && ok "(the empty skeleton really is there)" || bad "shim did not reproduce the leftover"

echo "===== the next start is not refused as a broken repository forever ====="
out="$("${APP[@]}" bash "$NS" start "$P" --no-attach 2>&1)"; rc=$?
case "$out" in *"сховище пошкоджене"*) bad "refused as broken: $out" ;; *) ok "not refused as a broken repository" ;; esac
[ "$rc" = 79 ] && ok "it reaches the real question again (79)" || bad "exit $rc: $out"
[ -e "$P/.git" ] && bad ".git left after an ordinary removal" || ok "and this time the .git is gone"
[ -f "$P/rec.mov" ] && [ -f "$P/a.txt" ] && ok "every file is still on disk" || bad "a file is gone"

echo "===== a broken .git with anything in it is still refused, never removed ====="
B="$TMP/broken"; mkdir -p "$B/.git/objects"; echo junk > "$B/.git/HEAD"; echo x > "$B/f.txt"
bash "$NS" allow-git "$B" >/dev/null 2>&1
out="$("${APP[@]}" bash "$NS" start "$B" --no-attach 2>&1)"; rc=$?
case "$out" in *"сховище пошкоджене"*) ok "refused as broken" ;; *) bad "exit $rc: $out" ;; esac
[ -f "$B/.git/HEAD" ] && ok "and left alone" || bad "a .git with content was removed"

echo "===== an empty skeleton in a folder nobody let us make git in is not ours to touch ====="
N="$TMP/notours"; mkdir -p "$N/.git/refs"; echo x > "$N/f.txt"
out="$("${APP[@]}" bash "$NS" start "$N" --no-attach 2>&1)"
[ -d "$N/.git/refs" ] && ok "left alone" || bad "removed a .git without consent"

echo "===== a skeleton whose walk fails is not proven empty, and is left alone ====="
U="$TMP/unreadable"; mkdir -p "$U/.git/objects/ab"; echo x > "$U/f.txt"; echo blob > "$U/.git/objects/ab/cd"
chmod 000 "$U/.git/objects"
( . "$BIN_DIR/supervisor-lib.sh" >/dev/null 2>&1; git_skeleton_only "$U" ) \
  && bad "an unreadable .git was judged empty" || ok "an unreadable .git is not judged empty"
bash "$NS" allow-git "$U" >/dev/null 2>&1
out="$("${APP[@]}" bash "$NS" start "$U" --no-attach 2>&1)"
chmod 755 "$U/.git/objects"
[ -f "$U/.git/objects/ab/cd" ] && ok "its content is still there" || bad "removed a .git it could not read: $out"

echo
[ "$fails" = 0 ] && echo "✅ created .git removal is verified" || { echo "❌ created .git removal: $fails problem(s)"; exit 1; }
