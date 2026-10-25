#!/bin/bash
# A resume that cannot happen says why, and the app hears it.
#
# 23 Oct, 1.16.1: a chat's message went to `night-shift.sh resume` for a conversation Claude Code
# no longer kept. Claude exited before any hook ran, the resume rolled back, and worker-send told
# the app only TIER=none — «Night Shift could not resume this conversation», a repair, and an
# anonymous error report. The same silence undid the sign-in fix of 22 Oct: the resume printed
# `handshake-blocked=login`, but worker-send sent everything the resume said to the log alone.
#
# Pinned here: a resume of a conversation with no transcript is refused before anything is touched,
# with a marker; worker-send passes the resume's marker lines on to the app.
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
set -u
unset SUPERVISOR_CHAT_CONTEXT_FILE SUPERVISOR_EXTRA_DIRS_FILE SUPERVISOR_CLAUDE_CMD SUPERVISOR_NIGHT_SHIFT_CMD
command -v tmux >/dev/null 2>&1 || { echo "SKIP: tmux not installed"; exit 0; }

TMP="$(mktemp -d)"
tmux_isolate "$TMP/tmux"
export SUPERVISOR_STATE_DIR="$TMP/state" CLAUDE_CONFIG_DIR="$TMP/claude"
mkdir -p "$SUPERVISOR_STATE_DIR" "$CLAUDE_CONFIG_DIR/projects"
. "$BIN_DIR/supervisor-lib.sh"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [$2]"; fi; }

cleanup() { tmux_cleanup; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

PROJ="$TMP/old-chat"
mkdir -p "$PROJ"
( cd "$PROJ" && git init -q && git config user.email t@t && git config user.name t \
    && echo x > f.txt && git add -A && git commit -qm init >/dev/null )
PROJ="$(canon_path "$PROJ")"
SLUG="$(slug_for "$PROJ")"; IDIR="$(instance_dir "$SLUG")"; SES="$(session_name "$SLUG")"
SID="9a0c51e2-test-4d1f-8b3e-resumegone01"
export SUPERVISOR_ENABLE_RESUME=1 SUPERVISOR_NO_ATTACH=1

# The run the resume would replace — it must still be there, untouched, after a refusal.
mkdir -p "$IDIR/reports"
printf '%s\n' "$PROJ" > "$IDIR/project"
printf 'OLD-RUN\n' > "$IDIR/run-id"
printf '%s' "$SID" > "$IDIR/claude-session-id"
printf '{"verdict":"FAIL"}' > "$IDIR/reports/review.json"

echo "===== a conversation Claude Code no longer keeps is refused before anything is touched ====="
out="$(cd "$PROJ" && bash "$BIN_DIR/night-shift.sh" resume "$PROJ" "$SID" - --no-attach 2>&1)"; rc=$?
check "the resume is refused"                      '[ "$rc" != 0 ]'
check "with the marker the app reads"              'printf "%s\n" "$out" | grep -qx "resume-refused=transcript"'
check "no Claude was started for it"               '! tmux has-session -t "$SES" 2>/dev/null'
check "the previous run is where it was"           '[ "$(cat "$IDIR/run-id" 2>/dev/null)" = OLD-RUN ] && [ -s "$IDIR/reports/review.json" ]'
check "nothing is left aside"                      '[ -z "$(ls -A "$SUPERVISOR_STATE_DIR/resume-aside" 2>/dev/null)" ]'
check "the log says why"                           'grep -q "keeps no transcript of $SID" "$SUPERVISOR_STATE_DIR/supervisor.log"'

echo "===== a conversation it keeps is not refused for that ====="
mkdir -p "$CLAUDE_CONFIG_DIR/projects/-tmp-old-chat"
: > "$CLAUDE_CONFIG_DIR/projects/-tmp-old-chat/$SID.jsonl"
check "a transcript in any project folder counts"  'claude_transcript_kept "$SID"'
check "another id is still not kept"               '! claude_transcript_kept "someone-else"'
check "an empty id is not kept"                    '! claude_transcript_kept ""'
rm -f "$CLAUDE_CONFIG_DIR/projects/-tmp-old-chat/$SID.jsonl"

echo "===== worker-send passes the refusal on to the app ====="
out="$(bash "$BIN_DIR/worker-send.sh" "$PROJ" "$SID" "-" "" "привіт" 2>&1)"; rc=$?
check "TIER=none, exit 3, as before"               '[ "$rc" = 3 ] && printf "%s\n" "$out" | grep -qx "TIER=none"'
check "and the marker with it"                     'printf "%s\n" "$out" | grep -qx "resume-refused=transcript"'
check "the resume's words still reach the log"     'grep -q "більше не зберігає цю розмову" "$SUPERVISOR_STATE_DIR/supervisor.log"'

echo "===== a resume stopped on a sign-in reaches the app as one ====="
# The resume's own words when Claude asked for a sign-in and exited (handshake_blocker → login).
printf '#!/bin/bash\necho "⚠️ хуки не підтвердили run-id за 60s" >&2\necho "handshake-blocked=login" >&2\nexit 1\n' > "$TMP/signed-out-resume"
chmod +x "$TMP/signed-out-resume"
out="$(SUPERVISOR_NIGHT_SHIFT_CMD="$TMP/signed-out-resume" bash "$BIN_DIR/worker-send.sh" "$PROJ" "$SID" "-" "" "привіт" 2>&1)"; rc=$?
check "the sign-in marker is in what the app reads" 'printf "%s\n" "$out" | grep -qx "handshake-blocked=login"'
check "only marker lines, not the resume's prose"  '! printf "%s\n" "$out" | grep -q "хуки не підтвердили"'

echo
[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAIL"; exit 1; }
