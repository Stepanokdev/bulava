#!/bin/bash
# A resume is given the time a resume takes, never starts a conversation twice, and a failed one
# leaves things as they were.
#
# 4 Oct, 17:22: a message to a long chat went to `night-shift.sh resume`. Claude read its 41 MB
# transcript and was at its prompt, but the launcher waited the fresh start's five seconds for the
# SessionStart handshake, rolled the start back, deleted the run's folder with its review in it, and
# the app said «Night Shift could not resume this conversation». The same afternoon, an older Bulava
# sent an automation's follow-up to his own folder while the run was alive in its copy, and the engine
# resumed that conversation a second time there.
#
# Pinned here: a resume waits its own budget; a worker that is gone, or stopped on a screen no hook
# runs past, ends the wait at once; a resume that does not come up puts the previous run back; and a
# conversation already alive in another run is refused before anything is touched.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$ROOT/bin"
unset SUPERVISOR_CHAT_CONTEXT_FILE SUPERVISOR_EXTRA_DIRS_FILE SUPERVISOR_CLAUDE_CMD
unset SUPERVISOR_REQUIRE_HANDSHAKE SUPERVISOR_HANDSHAKE_WAIT SUPERVISOR_RESUME_HANDSHAKE_WAIT
command -v tmux >/dev/null 2>&1 || { echo "SKIP: tmux not installed"; exit 0; }

TMP="$(mktemp -d)"
tmux_isolate "$TMP/tmux"
export SUPERVISOR_STATE_DIR="$TMP/state"
mkdir -p "$SUPERVISOR_STATE_DIR"
. "$BIN_DIR/supervisor-lib.sh"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [$2]"; fi; }

STUB_PIDS=""
cleanup() {
  [ -n "$STUB_PIDS" ] && kill $STUB_PIDS 2>/dev/null
  tmux_cleanup
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

PROJ="$TMP/long-chat"
mkdir -p "$PROJ"
( cd "$PROJ" && git init -q && git config user.email t@t && git config user.name t \
    && echo x > f.txt && git add -A && git commit -qm init >/dev/null )
PROJ="$(canon_path "$PROJ")"
SLUG="$(slug_for "$PROJ")"; IDIR="$(instance_dir "$SLUG")"; SES="$(session_name "$SLUG")"
SID="5e1f0a77-test-4c2b-9d1e-resumehandshk"

printf '#!/bin/bash\nsleep 120\n' > "$TMP/watchdog-stub"; chmod +x "$TMP/watchdog-stub"
export SUPERVISOR_WATCHDOG_CMD="$TMP/watchdog-stub" SUPERVISOR_ENABLE_RESUME=1 SUPERVISOR_NO_ATTACH=1

# A Claude that reads its transcript for $1 seconds before the SessionStart hook confirms the run —
# the hook's own effect, written where the hook writes it.
slow_claude() { printf 'sleep %s; : > %s; sleep 120' "$1" "$(shq "$IDIR/handshake-ok")"; }

# The run a resume replaces: its review and its run id, the things the app reads with it.
old_run() {
  rm -rf "$IDIR"; mkdir -p "$IDIR/reports"
  printf '%s\n' "$PROJ" > "$IDIR/project"
  printf 'OLD-RUN\n' > "$IDIR/run-id"
  printf '%s' "$SID" > "$IDIR/claude-session-id"
  printf '{"verdict":"FAIL"}' > "$IDIR/reports/review.json"
}

resume() {  # extra env assignments, then nothing — always the same conversation
  ( cd "$PROJ" && env "$@" bash "$BIN_DIR/night-shift.sh" resume "$PROJ" "$SID" - --no-attach 2>&1 )
}

echo "===== a resume waits for a transcript longer than a fresh start would ====="
old_run
t0=$(date +%s)
out="$(resume SUPERVISOR_CLAUDE_CMD="$(slow_claude 4)" SUPERVISOR_HANDSHAKE_WAIT=2 SUPERVISOR_RESUME_HANDSHAKE_WAIT=15)"; rc=$?
t1=$(date +%s)
check "the resume is confirmed after the fresh-start budget ran out" '[ "$rc" = 0 ]'
check "it says it resumed"                         'printf "%s" "$out" | grep -q "Відновлено"'
check "the session is up"                          'tmux has-session -t "$SES" 2>/dev/null'
check "the new run replaced the old one"           '[ "$(cat "$IDIR/run-id")" != OLD-RUN ]'
check "nothing of the old run is left aside"       '[ -z "$(ls -A "$SUPERVISOR_STATE_DIR/resume-aside" 2>/dev/null)" ]'
check "the log says how long the handshake took"   'grep -q "handshake confirmed after [0-9]*s ($SLUG)" "$SUPERVISOR_STATE_DIR/supervisor.log"'
check "and it did not wait the whole budget"       '[ $((t1 - t0)) -lt 12 ]'
STUB_PIDS="$(cat "$IDIR/watchdog.pid" 2>/dev/null)"
tmux kill-session -t "$SES" 2>/dev/null; kill $STUB_PIDS 2>/dev/null; STUB_PIDS=""

echo "===== a fresh start keeps its own short budget ====="
rm -rf "$IDIR"
out="$(cd "$PROJ" && SUPERVISOR_CLAUDE_CMD="$(slow_claude 4)" SUPERVISOR_HANDSHAKE_WAIT=2 SUPERVISOR_RESUME_HANDSHAKE_WAIT=15 \
       bash "$BIN_DIR/night-shift.sh" start "$PROJ" --no-attach 2>&1)"; rc=$?
check "the same slow worker is refused on a fresh start" '[ "$rc" != 0 ]'
tmux kill-session -t "$SES" 2>/dev/null

echo "===== a resume that does not come up puts the previous run back ====="
old_run
out="$(resume SUPERVISOR_CLAUDE_CMD="sleep 120" SUPERVISOR_HANDSHAKE_WAIT=1 SUPERVISOR_RESUME_HANDSHAKE_WAIT=2)"; rc=$?
check "the resume is refused"                      '[ "$rc" != 0 ]'
check "and says there was no confirmation"         'printf "%s" "$out" | grep -q "підтвердження нема"'
check "the previous run is back in its place"      '[ "$(cat "$IDIR/run-id" 2>/dev/null)" = OLD-RUN ]'
check "with its review"                            'grep -q FAIL "$IDIR/reports/review.json" 2>/dev/null'
check "nothing is left aside"                      '[ -z "$(ls -A "$SUPERVISOR_STATE_DIR/resume-aside" 2>/dev/null)" ]'
check "no session is left running"                 '! tmux has-session -t "$SES" 2>/dev/null'

echo "===== a worker that is gone ends the wait at once ====="
old_run
t0=$(date +%s)
out="$(resume SUPERVISOR_CLAUDE_CMD="sleep 2" SUPERVISOR_HANDSHAKE_WAIT=5 SUPERVISOR_RESUME_HANDSHAKE_WAIT=60)"; rc=$?
t1=$(date +%s)
check "refused"                                    '[ "$rc" != 0 ]'
check "as a worker that exited"                    'printf "%s" "$out" | grep -q "^handshake-blocked=exited$"'
check "without sitting out the minute"             '[ $((t1 - t0)) -lt 10 ]'
check "and the previous run is back"               '[ "$(cat "$IDIR/run-id" 2>/dev/null)" = OLD-RUN ]'

echo "===== a screen no hook runs past ends the wait at once ====="
old_run
printf '%s\n' '#!/bin/bash' 'printf " Quick safety check: Is this a project you created or one you trust?\n ❯ No, exit\n   Yes, I trust this folder\n"' 'sleep 120' > "$TMP/trust-claude.sh"
chmod +x "$TMP/trust-claude.sh"
t0=$(date +%s)
out="$(resume SUPERVISOR_CLAUDE_CMD="$TMP/trust-claude.sh" SUPERVISOR_HANDSHAKE_WAIT=5 SUPERVISOR_RESUME_HANDSHAKE_WAIT=60)"; rc=$?
t1=$(date +%s)
check "refused"                                    '[ "$rc" != 0 ]'
check "naming the trust question"                  'printf "%s" "$out" | grep -q "^handshake-blocked=trust$"'
check "without sitting out the minute"             '[ $((t1 - t0)) -lt 12 ]'
check "no session is left running"                '! tmux has-session -t "$SES" 2>/dev/null'

echo "===== a conversation alive in another run is not started a second time ====="
old_run
OTHER_SLUG="automation-copy-a04f122d-a31546d7fdfa"
OTHER_IDIR="$(instance_dir "$OTHER_SLUG")"
mkdir -p "$OTHER_IDIR"; printf '%s' "$SID" > "$OTHER_IDIR/claude-session-id"
tmux new-session -d -s "$(session_name "$OTHER_SLUG")" "sleep 120"
out="$(resume SUPERVISOR_CLAUDE_CMD="$(slow_claude 1)" SUPERVISOR_HANDSHAKE_WAIT=2)"; rc=$?
check "the resume is refused as held elsewhere"    '[ "$rc" = 4 ]'
check "naming where it runs"                       'printf "%s" "$out" | grep -q "$OTHER_SLUG"'
check "nothing was started here"                   '! tmux has-session -t "$SES" 2>/dev/null'
check "and the run here was not touched"           '[ "$(cat "$IDIR/run-id" 2>/dev/null)" = OLD-RUN ] && [ -f "$IDIR/reports/review.json" ]'
check "the log says why"                           'grep -q "REFUSED .*live in $OTHER_SLUG" "$SUPERVISOR_STATE_DIR/supervisor.log"'
tmux kill-session -t "$(session_name "$OTHER_SLUG")" 2>/dev/null

check "once that session has ended, the record alone holds nothing" \
      '! claude_session_holder "$SID" "$SLUG" >/dev/null'
( exec -a "claude --resume $SID --effort xhigh" sleep 30 ) &
HOLDER_PID=$!; STUB_PIDS="$HOLDER_PID"; sleep 0.3
check "a Claude resuming it by id, wherever it was started, holds it" \
      '[ "$(claude_session_holder "$SID" "$SLUG")" = "pid $HOLDER_PID" ]'
kill "$HOLDER_PID" 2>/dev/null; STUB_PIDS=""
# The message travels in worker-send's own arguments, and a shell wraps every launch line. Neither
# is a Claude, whatever text they carry.
( exec -a "bash worker-send.sh --mode conversation $PROJ $SID - - перезапусти claude --resume $SID" sleep 30 ) &
QUOTE_PID=$!
( exec -a "zsh -c env ORCHESTRATOR_RUN_ID=x claude --resume '$SID' --effort xhigh" sleep 30 ) &
SHELL_PID=$!; STUB_PIDS="$QUOTE_PID $SHELL_PID"; sleep 0.3
check "a message or a shell that only mentions the command holds nothing" \
      '! claude_session_holder "$SID" "$SLUG" >/dev/null'
kill $STUB_PIDS 2>/dev/null; STUB_PIDS=""
rm -rf "$OTHER_IDIR"

echo "===== a resume that cannot put the previous run aside changes nothing ====="
old_run
rm -rf "$SUPERVISOR_STATE_DIR/resume-aside"
: > "$SUPERVISOR_STATE_DIR/resume-aside"          # a file where the folder for it should go
out="$(resume SUPERVISOR_CLAUDE_CMD="$(slow_claude 1)" SUPERVISOR_HANDSHAKE_WAIT=2)"; rc=$?
check "refused"                                    '[ "$rc" != 0 ]'
check "the previous run is exactly where it was"   '[ "$(cat "$IDIR/run-id" 2>/dev/null)" = OLD-RUN ] && [ -f "$IDIR/reports/review.json" ]'
check "nothing was started"                        '! tmux has-session -t "$SES" 2>/dev/null'
tmux kill-session -t "$SES" 2>/dev/null
rm -f "$SUPERVISOR_STATE_DIR/resume-aside"

echo "===== a run being brought back by someone else is left to them ====="
old_run
mkdir -p "$SUPERVISOR_STATE_DIR/locks/revive-$SLUG"; printf '%s\n' "$$" > "$SUPERVISOR_STATE_DIR/locks/revive-$SLUG/pid"
out="$(resume SUPERVISOR_CLAUDE_CMD="$(slow_claude 1)" SUPERVISOR_HANDSHAKE_WAIT=2)"; rc=$?
check "refused while the revival holds the run"   '[ "$rc" != 0 ]'
check "its folder untouched"                       '[ "$(cat "$IDIR/run-id" 2>/dev/null)" = OLD-RUN ]'
check "and the revival keeps its lock"            '[ "$(cat "$SUPERVISOR_STATE_DIR/locks/revive-$SLUG/pid")" = "$$" ]'
rm -rf "$SUPERVISOR_STATE_DIR/locks/revive-$SLUG"
out="$(resume SUPERVISOR_CLAUDE_CMD="$(slow_claude 1)" SUPERVISOR_HANDSHAKE_WAIT=2)"; rc=$?
check "a resume that went through lets go of the lock" '[ "$rc" = 0 ] && [ ! -d "$SUPERVISOR_STATE_DIR/locks/revive-$SLUG" ]'
STUB_PIDS="$(cat "$IDIR/watchdog.pid" 2>/dev/null)"
tmux kill-session -t "$SES" 2>/dev/null; kill $STUB_PIDS 2>/dev/null; STUB_PIDS=""

echo "===== two folders resuming one conversation at the same moment: one worker, the other untouched ====="
# His folder and the run's copy, both asked to resume the same conversation at once — the shape of
# 4 Oct, without the minutes in between. Each would find nobody running it yet.
mkrepo() {
  local d="$TMP/$1"; mkdir -p "$d"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t \
      && echo x > f.txt && git add -A && git commit -qm init >/dev/null )
  canon_path "$d"
}
PA="$(mkrepo his-folder)"; PB="$(mkrepo the-copy)"
IA="$(instance_dir "$(slug_for "$PA")")"; IB="$(instance_dir "$(slug_for "$PB")")"
SA="$(session_name "$(slug_for "$PA")")"; SB="$(session_name "$(slug_for "$PB")")"
seed() {  # $1=instance dir $2=project $3=run id
  rm -rf "$1"; mkdir -p "$1/reports"
  printf '%s\n' "$2" > "$1/project"; printf '%s\n' "$3" > "$1/run-id"
  printf '{"verdict":"FAIL"}' > "$1/reports/review.json"
}
seed "$IA" "$PA" OLD-A; seed "$IB" "$PB" OLD-B
# What the SessionStart hook writes once a resumed Claude has loaded its transcript: the
# conversation's id, then the handshake.
resumed_claude() {
  printf 'sleep 2; printf %%s %s > %s; : > %s; sleep 120' \
    "$(shq "$SID")" "$(shq "$1/claude-session-id")" "$(shq "$1/handshake-ok")"
}
both_resume() {
  ( cd "$PA" && SUPERVISOR_CLAUDE_CMD="$(resumed_claude "$IA")" SUPERVISOR_HANDSHAKE_WAIT=2 SUPERVISOR_RESUME_HANDSHAKE_WAIT=15 \
      bash "$BIN_DIR/night-shift.sh" resume "$PA" "$SID" - --no-attach > "$TMP/a.out" 2>&1; echo $? > "$TMP/a.rc" ) &
  local pa=$!
  ( cd "$PB" && SUPERVISOR_CLAUDE_CMD="$(resumed_claude "$IB")" SUPERVISOR_HANDSHAKE_WAIT=2 SUPERVISOR_RESUME_HANDSHAKE_WAIT=15 \
      bash "$BIN_DIR/night-shift.sh" resume "$PB" "$SID" - --no-attach > "$TMP/b.out" 2>&1; echo $? > "$TMP/b.rc" ) &
  local pb=$!
  wait "$pa" "$pb"
}
both_resume
ra="$(cat "$TMP/a.rc")"; rb="$(cat "$TMP/b.rc")"
live=0
tmux has-session -t "$SA" 2>/dev/null && live=$((live + 1))
tmux has-session -t "$SB" 2>/dev/null && live=$((live + 1))
check "exactly one of them came up ($ra/$rb)"      '{ [ "$ra" = 0 ] && [ "$rb" = 4 ]; } || { [ "$ra" = 4 ] && [ "$rb" = 0 ]; }'
check "one worker is running, not two"             '[ "$live" = 1 ]'
if [ "$ra" = 0 ]; then WIN_I="$IA" WIN_S="$SA" LOSE_P="$PB" LOSE_I="$IB" LOSE_S="$SB" LOSE_OLD=OLD-B
else WIN_I="$IB" WIN_S="$SB" LOSE_P="$PA" LOSE_I="$IA" LOSE_S="$SA" LOSE_OLD=OLD-A; fi
check "the refused folder's run is exactly as it was" \
      '[ "$(cat "$LOSE_I/run-id" 2>/dev/null)" = "$LOSE_OLD" ] && grep -q FAIL "$LOSE_I/reports/review.json" 2>/dev/null'
check "and nothing was started there"              '! tmux has-session -t "$LOSE_S" 2>/dev/null'
check "the conversation's lock is not left behind" '[ ! -d "$(_session_lock_dir "$SID")" ]'

# Later, once the winner is up: the other folder is refused by who is running it, not by a lock.
out="$(cd "$LOSE_P" && SUPERVISOR_CLAUDE_CMD="$(resumed_claude "$LOSE_I")" SUPERVISOR_HANDSHAKE_WAIT=2 \
       bash "$BIN_DIR/night-shift.sh" resume "$LOSE_P" "$SID" - --no-attach 2>&1)"; rc=$?
check "a later resume from the other folder is refused" '[ "$rc" = 4 ] && printf "%s" "$out" | grep -q "$(basename "$WIN_I")"'
check "and its run is still untouched"             '[ "$(cat "$LOSE_I/run-id" 2>/dev/null)" = "$LOSE_OLD" ]'
STUB_PIDS="$(cat "$WIN_I/watchdog.pid" 2>/dev/null)"
tmux kill-session -t "$WIN_S" 2>/dev/null; kill $STUB_PIDS 2>/dev/null; STUB_PIDS=""

# A run that owes work and can be brought back in place (`instance_revive`): its own conversation id,
# a launch template, and a Claude stand-in that loads for two seconds before the hook confirms it.
cat > "$TMP/revived-claude.sh" <<'SH'
#!/bin/bash
idir="$1"; shift
printf '%s\n' "$*" >> "$idir/launches.log"
sleep 2
: > "$idir/handshake-ok"
sleep 120
SH
chmod +x "$TMP/revived-claude.sh"
revivable() {  # $1=instance dir $2=project $3=run id
  seed "$1" "$2" "$3"
  printf '%s\n' "$(session_name "$(basename "$1")")" > "$1/session"
  printf '%s' "$SID" > "$1/claude-session-id"
  printf 'old-generation\n' > "$1/worker-generation"
  : > "$1/started-at"
  printf '%s\n' "$(shq "$TMP/revived-claude.sh") $(shq "$1") --resume @CLAUDE_SESSION@; true stop --generation @GENERATION@" > "$1/relaunch-template"
}
untouched_revivable() {  # $1=instance dir $2=run id — refused, so exactly as it was
  [ "$(cat "$1/run-id" 2>/dev/null)" = "$2" ] && [ "$(cat "$1/worker-generation" 2>/dev/null)" = old-generation ] \
    && [ ! -s "$1/launches.log" ] && grep -q FAIL "$1/reports/review.json" 2>/dev/null
}
clear_both() {
  local d
  for d in "$IA" "$IB"; do kill "$(cat "$d/watchdog.pid" 2>/dev/null)" 2>/dev/null; done
  tmux kill-session -t "$SA" 2>/dev/null; tmux kill-session -t "$SB" 2>/dev/null
  pkill -f "$TMP/revived-claude.sh" 2>/dev/null; sleep 0.3
}
live_workers() {
  local n=0
  tmux has-session -t "$SA" 2>/dev/null && n=$((n + 1))
  tmux has-session -t "$SB" 2>/dev/null && n=$((n + 1))
  echo "$n"
}

echo "===== a resume in one folder and a revival in another, at once: one worker ====="
clear_both
seed "$IA" "$PA" OLD-A
revivable "$IB" "$PB" RUN-B
( cd "$PA" && SUPERVISOR_CLAUDE_CMD="$(resumed_claude "$IA")" SUPERVISOR_HANDSHAKE_WAIT=2 SUPERVISOR_RESUME_HANDSHAKE_WAIT=15 \
    bash "$BIN_DIR/night-shift.sh" resume "$PA" "$SID" - --no-attach > "$TMP/a.out" 2>&1; echo $? > "$TMP/a.rc" ) &
pa=$!
( SUPERVISOR_REVIVE_HANDSHAKE_WAIT=15 bash "$BIN_DIR/night-shift.sh" revive "$PB" > "$TMP/b.out" 2>&1; echo $? > "$TMP/b.rc" ) &
pb=$!
wait "$pa" "$pb"
ra="$(cat "$TMP/a.rc")"; rb="$(cat "$TMP/b.rc")"
check "exactly one of them came up (resume $ra / revive $rb)" \
      '{ [ "$ra" = 0 ] && [ "$rb" = 5 ]; } || { [ "$ra" = 4 ] && [ "$rb" = 0 ]; }'
check "one worker is running, not two"             '[ "$(live_workers)" = 1 ]'
if [ "$ra" = 0 ]; then
  check "the refused revival left its run exactly as it was" 'untouched_revivable "$IB" RUN-B'
else
  check "the refused resume left its run exactly as it was" \
        '[ "$(cat "$IA/run-id" 2>/dev/null)" = OLD-A ] && grep -q FAIL "$IA/reports/review.json"'
fi
check "no conversation lock is left behind"        '[ ! -d "$(_session_lock_dir "$SID")" ]'
check "nor a folder lock"                          '[ -z "$(ls "$SUPERVISOR_STATE_DIR/locks" 2>/dev/null | grep "^revive-")" ]'

echo "===== two revivals of one conversation in two folders, at once: one worker ====="
clear_both
revivable "$IA" "$PA" RUN-A
revivable "$IB" "$PB" RUN-B
( SUPERVISOR_REVIVE_HANDSHAKE_WAIT=15 bash "$BIN_DIR/night-shift.sh" revive "$PA" > "$TMP/a.out" 2>&1; echo $? > "$TMP/a.rc" ) &
pa=$!
( SUPERVISOR_REVIVE_HANDSHAKE_WAIT=15 bash "$BIN_DIR/night-shift.sh" revive "$PB" > "$TMP/b.out" 2>&1; echo $? > "$TMP/b.rc" ) &
pb=$!
wait "$pa" "$pb"
ra="$(cat "$TMP/a.rc")"; rb="$(cat "$TMP/b.rc")"
check "exactly one of them came up ($ra/$rb)"      '{ [ "$ra" = 0 ] && [ "$rb" = 5 ]; } || { [ "$ra" = 5 ] && [ "$rb" = 0 ]; }'
check "one worker is running, not two"             '[ "$(live_workers)" = 1 ]'
if [ "$ra" = 0 ]; then LOSE_I="$IB" LOSE_R=RUN-B WIN_P="$PA"; else LOSE_I="$IA" LOSE_R=RUN-A WIN_P="$PB"; fi
check "the refused one is exactly as it was"       'untouched_revivable "$LOSE_I" "$LOSE_R"'
check "no lock is left behind"                     '[ ! -d "$(_session_lock_dir "$SID")" ] && [ -z "$(ls "$SUPERVISOR_STATE_DIR/locks" 2>/dev/null | grep "^revive-")" ]'

# And afterwards: the run that lost is refused by who runs the conversation, not by a lock.
LOSE_P="$(cat "$LOSE_I/project")"
SUPERVISOR_REVIVE_HANDSHAKE_WAIT=15 bash "$BIN_DIR/night-shift.sh" revive "$LOSE_P" >/dev/null 2>&1; rc=$?
check "a later revival of the other one is refused" '[ "$rc" = 5 ] && untouched_revivable "$LOSE_I" "$LOSE_R"'
check "the log says where the conversation runs"   'grep -q "conversation $SID is live in" "$SUPERVISOR_STATE_DIR/supervisor.log"'
# A second ask for the run that is already up is that run's own business: no refusal, no second worker.
SUPERVISOR_REVIVE_HANDSHAKE_WAIT=15 bash "$BIN_DIR/night-shift.sh" revive "$WIN_P" >/dev/null 2>&1; rc=$?
check "asking again for the run that is up is a no-op" '[ "$rc" = 0 ] && [ "$(live_workers)" = 1 ]'
clear_both

echo "===== the app is told it is a conflict, not that nothing could be resumed ====="
rm -rf "$IDIR"
printf '#!/bin/bash\nexit 4\n' > "$TMP/ns-held"; chmod +x "$TMP/ns-held"
out="$(SUPERVISOR_NIGHT_SHIFT_CMD="$TMP/ns-held" bash "$BIN_DIR/worker-send.sh" "$PROJ" "$SID" - - "Глянь як пройшла автоматизація" 2>&1)"; rc=$?
check "worker-send exits as a conflict"            '[ "$rc" = 4 ]'
check "with the conflict tier"                     'printf "%s" "$out" | grep -q "^TIER=conflict$"'

echo "===== the budgets ====="
check "the resume budget defaults to a minute"     '[ "$(SUPERVISOR_HANDSHAKE_WAIT=5 resume_handshake_wait)" = 60 ]'
check "never shorter than a fresh start's"         '[ "$(SUPERVISOR_HANDSHAKE_WAIT=90 SUPERVISOR_RESUME_HANDSHAKE_WAIT=60 resume_handshake_wait)" = 90 ]'
check "and off where the handshake is off"         '[ "$(SUPERVISOR_HANDSHAKE_WAIT=0 resume_handshake_wait)" = 0 ]'
check "the config hands it to every process"      \
      '( unset SUPERVISOR_RESUME_HANDSHAKE_WAIT; . "$ROOT/supervisor/config.sh"; bash -c "[ \"\$SUPERVISOR_RESUME_HANDSHAKE_WAIT\" = 60 ]" )'

echo
[ "$fails" -eq 0 ] && echo "✅ resume handshake: all checks pass" || echo "❌ resume handshake: $fails failed"
[ "$fails" -eq 0 ]
