#!/bin/bash
# His words survive a launch that never became a supervised run.
#
# 25 Aug, Presale Copilot: the launcher brought a session up, the hooks never confirmed the run-id,
# the injection did not land, the message was parked — and then the run's folder was cleaned by a
# restart, taking the queue with it. He was left reading «Queued · waiting behind other
# work» about a message that no longer existed anywhere, while nothing was running at all.
#
# Three things are pinned here: the launch fails CLOSED when nobody confirms the run-id, a parked
# message outlives the folder of the run it was meant for, and one project's trouble is not another
# project's problem.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$ROOT/bin"
# The app bridge must not leak in from the surrounding shell: these variables are how Bulava
# says "this run is a direct chat", and a test asserting terminal semantics that inherits them
# measures its own environment instead of the product.
unset SUPERVISOR_CHAT_CONTEXT_FILE SUPERVISOR_EXTRA_DIRS_FILE
export SUPERVISOR_STATE_DIR="$(mktemp -d)"
# This suite is about the DEFAULTS. A shell that inherited the knobs from a running shift would
# otherwise test that shift's settings instead of the engine's own.
unset SUPERVISOR_REQUIRE_HANDSHAKE SUPERVISOR_HANDSHAKE_WAIT
. "$BIN_DIR/supervisor-lib.sh"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [$2]"; fi; }

TMP="$(mktemp -d)"
# Every tmux session this suite brings up is named after its temp project, so it can — and must —
# take them all with it. A test that leaves sessions running on his machine is litter that looks
# like work: `tmux ls` is where he checks what is going on.

# Two projects, because the point is that they are independent.
mkproj() {
  local d="$TMP/$1"; mkdir -p "$d"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t \
      && echo x > f.txt && git add -A && git commit -qm init >/dev/null )
  printf '%s' "$d"
}
PRESALE="$(mkproj bid-desk)"
OTHER="$(mkproj atlas-mobile)"
PRESALE_SESSION="$(session_name "$(slug_for "$PRESALE")")"
OTHER_SESSION="$(session_name "$(slug_for "$OTHER")")"

cleanup() {
  local ses
  # By exact name, derived from this run's own temp projects — never by pattern. A pattern that
  # matched "looks like one of ours" could reach a real project's session, and killing a running
  # worker to tidy a test is not a trade anyone would take.
  for ses in "${PRESALE_SESSION:-}" "${OTHER_SESSION:-}"; do
    [ -n "$ses" ] || continue
    tmux kill-session -t "$ses" 2>/dev/null || true
  done
  rm -rf "$SUPERVISOR_STATE_DIR" "$TMP"
}
trap cleanup EXIT

idir_for() { instance_dir "$(slug_for "$1")"; }
mkinstance() { local d; d="$(idir_for "$1")"; mkdir -p "$d"; printf '%s\n' "$2" > "$d/run-id"; printf '%s' "$d"; }

echo "===== a start nobody confirmed does not pretend to have started ====="
# The real launcher with the worker stubbed to `cat`: a session comes up and nothing ever writes
# handshake-ok, which is precisely what happened on 25 Aug. Fail-closed means a non-zero exit and
# no instance dir left behind, so the caller knows his message was never handed to anything.
tmux_isolate "$TMP/tmux"
out="$(cd "$PRESALE" && SUPERVISOR_CLAUDE_CMD="cat" SUPERVISOR_NO_ATTACH=1 \
       SUPERVISOR_HANDSHAKE_WAIT=1 \
       bash "$BIN_DIR/night-shift.sh" start "$PRESALE" --no-attach 2>&1)"; rc=$?
check "the launcher refuses the start"          '[ "$rc" != 0 ]'
check "and names the missing confirmation"      'printf "%s" "$out" | grep -q "підтвердження нема"'
check "no instance dir is left behind"          '[ ! -d "$(idir_for "$PRESALE")" ]'
check "and no tmux session is left running"     '! tmux has-session -t "$(session_name "$(slug_for "$PRESALE")")" 2>/dev/null'
check "warning and carrying on is still available" \
      '(cd "$PRESALE" && SUPERVISOR_CLAUDE_CMD="cat" SUPERVISOR_NO_ATTACH=1 SUPERVISOR_HANDSHAKE_WAIT=1 SUPERVISOR_REQUIRE_HANDSHAKE=0 bash "$BIN_DIR/night-shift.sh" start "$PRESALE" --no-attach >/dev/null 2>&1)'
"$BIN_DIR/night-shift.sh" stop "$PRESALE" >/dev/null 2>&1 || true
rm -rf "$(idir_for "$PRESALE")"

echo "===== a parked message outlives the run's own folder ====="
IDIR="$(mkinstance "$PRESALE" RUN-A)"
park_undelivered "$IDIR" "Братику, є фідбек по додатку" "MSG-1"
Q="$(undelivered_file "$IDIR")"
check "the message is on disk"                  '[ -s "$Q" ]'
check "it is NOT inside the run folder"         '[ ! -f "$IDIR/undelivered.jsonl" ]'
check "it remembers which run it was for"       '[ "$(jq -r .run_id < "$Q")" = "RUN-A" ]'
rm -rf "$IDIR"                                   # restart / teardown / rollback
check "and it survives the folder being wiped"  '[ -s "$Q" ] && grep -q "фідбек" "$Q"'

echo "===== but it is never dropped into a later, unrelated run ====="
IDIR="$(mkinstance "$PRESALE" RUN-B)"            # a new run for the same project
inject_task() { : > "$TMP/injected"; return 0; }
rm -f "$TMP/injected"
flush_undelivered fake-session "$IDIR" >/dev/null 2>&1
check "it was not injected into the new run"    '[ ! -f "$TMP/injected" ]'
check "the queue is empty now"                  '[ ! -s "$Q" ]'
check "and it is recorded as undelivered"       'grep -q "фідбек" "$(undelivered_stuck_file "$IDIR")"'
check "with the reason on the record"           'grep -q "run gone before delivery" "$(undelivered_stuck_file "$IDIR")"'

echo "===== a message for the LIVE run is still delivered ====="
park_undelivered "$IDIR" "А це для поточного прогону" "MSG-2"
rm -f "$TMP/injected"
flush_undelivered fake-session "$IDIR" >/dev/null 2>&1
check "delivered"                               '[ -f "$TMP/injected" ]'
check "and taken off the queue"                 '[ ! -s "$(undelivered_file "$IDIR")" ]'

echo "===== the other project is untouched by any of it ====="
OIDIR="$(mkinstance "$OTHER" RUN-O)"
park_undelivered "$OIDIR" "Робота в іншому проєкті" "MSG-3"
check "its queue is its own"                    '[ "$(undelivered_file "$OIDIR")" != "$(undelivered_file "$(idir_for "$PRESALE")")" ]'
rm -f "$TMP/injected"
flush_undelivered fake-session "$OIDIR" >/dev/null 2>&1
check "and it delivers while the other is stuck" '[ -f "$TMP/injected" ]'
check "nothing of the other project leaked in"  '! grep -q "фідбек" "$(undelivered_file "$OIDIR")" 2>/dev/null'

echo "===== resume demands the same confirmation as a fresh start ====="
# This path brought a session up and returned success without ever asking whether the hooks could
# see the run-id. An unsupervised resumed session is exactly as unsupervised as a new one.
# The lenient start above left a session on purpose (`night-shift stop` keeps the session and
# removes the supervision — that is the very shape this suite is about), so clear the ground first.
tmux kill-session -t "$(session_name "$(slug_for "$PRESALE")")" 2>/dev/null || true
rm -rf "$(idir_for "$PRESALE")"
out="$(cd "$PRESALE" && SUPERVISOR_CLAUDE_CMD="cat" SUPERVISOR_NO_ATTACH=1 \
       SUPERVISOR_HANDSHAKE_WAIT=1 \
       bash "$BIN_DIR/night-shift.sh" resume "$PRESALE" "some-session-id" - --no-attach 2>&1)"; rc=$?
check "resume refuses without the confirmation"  '[ "$rc" != 0 ]'
check "and rolls its own launch back"            '[ ! -d "$(idir_for "$PRESALE")" ]'
check "leaving no session behind"                '! tmux has-session -t "$(session_name "$(slug_for "$PRESALE")")" 2>/dev/null'

echo "===== dispatch never injects into a session nothing is watching ====="
# `night-shift stop` leaves the tmux session alive and removes the instance dir. Reuse used to see
# "a session exists", rebuild the folder and a watchdog around a worker whose run-id matched
# nothing, and hand it work — which the app then accepted as a started, supervised run.
SESS="$(session_name "$(slug_for "$PRESALE")")"
rm -rf "$(idir_for "$PRESALE")"
tmux new-session -d -s "$SESS" "cat" 2>/dev/null
check "the orphan session is up"                 'tmux has-session -t "$SESS" 2>/dev/null'
out="$(cd "$PRESALE" && SUPERVISOR_CLAUDE_CMD="cat" SUPERVISOR_NO_ATTACH=1 \
       SUPERVISOR_HANDSHAKE_WAIT=1 \
       bash "$BIN_DIR/dispatch.sh" "$PRESALE" "зроби вкладку" 2>&1)"; rc=$?
check "dispatch does not accept it"              '[ "$rc" != 0 ]'
check "it says a restart was needed"             'grep -q "not a confirmed supervised run" "$SUPERVISOR_STATE_DIR/supervisor.log"'
check "the unwatched session is gone"            '! tmux has-session -t "$SESS" 2>/dev/null'
check "and nothing was left claiming to run"     '[ ! -f "$(idir_for "$PRESALE")/watchdog.pid" ]'

echo "===== while a CONFIRMED run in another project takes its work ====="
OSESS="$(session_name "$(slug_for "$OTHER")")"
OIDIR2="$(mkinstance "$OTHER" RUN-CONFIRMED)"
: > "$OIDIR2/handshake-ok"
printf '%s\n' "$OTHER" > "$OIDIR2/project"
tmux new-session -d -s "$OSESS" "cat" 2>/dev/null
cat > "$TMP/wd-stub" <<'WD'
#!/bin/bash
sleep 60
WD
chmod +x "$TMP/wd-stub"
out="$(cd "$OTHER" && SUPERVISOR_WATCHDOG_CMD="$TMP/wd-stub" SUPERVISOR_HANDSHAKE_WAIT=1 \
       SUPERVISOR_PROMPT_WAIT=1 SUPERVISOR_INJECT_SETTLE=1 SUPERVISOR_INJECT_ENTER_TRIES=1 \
       bash "$BIN_DIR/dispatch.sh" "$OTHER" "робота в іншому проєкті" 2>&1)"; rc=$?
check "the other project is dispatched"          '[ "$rc" = 0 ]'
check "as a REUSE, not a restart"                '! printf "%s" "$out" | grep -q "Нічна зміна"'
check "its own run id is untouched"              '[ "$(cat "$OIDIR2/run-id")" = "RUN-CONFIRMED" ]'
tmux kill-session -t "$OSESS" 2>/dev/null || true

echo
[ "$fails" = 0 ] && echo "RESULT: a typed message is never lost, and never late" \
                 || echo "RESULT: $fails failed"
exit $([ "$fails" = 0 ] && echo 0 || echo 1)
