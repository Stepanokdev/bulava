#!/bin/bash
# A run that died with work still owed comes back in place.
#
# What happened: a chat parked on Codex's usage window, owing its review, with the director's signed
# answer to wait. Its tmux session and its watchdog died together a few minutes before Codex came
# back, and nothing ever brought it back: the watchdog sleeps while its session is missing, a dead
# watchdog does nothing, and a message to it went through `resume`, which deletes the instance and
# starts a new run — the owed review with it. A real (isolated) tmux runs stand-ins for Claude and
# the watchdog. Asserted:
#   - `night-shift.sh revive` starts the same conversation again in the same instance: run id, the
#     debt, the signed decision, decisions and checks untouched; a new generation; a watchdog
#   - a second call on a whole run starts nothing; a stopped run, or one whose Claude still runs, is
#     refused
#   - a message to a dead run that owes work revives it instead of `resume`: nothing deleted
#   - the SessionStart sweep leaves an old run that owes work alone
#   - a watchdog whose session was killed starts its worker again
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

command -v tmux >/dev/null 2>&1 || { echo "SKIP: tmux not installed"; exit 0; }

TMP="$(mktemp -d -t revive)" || exit 1
tmux_isolate "$TMP/tmux"
cleanup() {
  [ -n "${STUB_PIDS:-}" ] && kill $STUB_PIDS 2>/dev/null
  pkill -f "$TMP/fake-" 2>/dev/null
  tmux_cleanup; rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR/instances"
export HOME="$TMP/home"; mkdir -p "$HOME/.claude/sessions"
export SUPERVISOR_CLAUDE_USAGE_CMD=/usr/bin/true SUPERVISOR_CODEX_USAGE_CMD=/usr/bin/true
export SUPERVISOR_CLAUDE_REACHABLE_CMD=/usr/bin/true
export SUPERVISOR_REVIVE_HANDSHAKE_WAIT=15
. "$BIN_DIR/supervisor-lib.sh"

PROJ="$TMP/project"; mkdir -p "$PROJ"
SLUG="$(slug_for "$PROJ")"; IDIR="$(instance_dir "$SLUG")"; SESSION="$(session_name "$SLUG")"
SID="$(uuidgen | tr "[:upper:]" "[:lower:]")"   # never a real conversation: a live one would be found running
RID="$(uuidgen)"

# The stand-in for Claude: says it started (the SessionStart hook's handshake), records how it was
# launched, and waits for input as a worker does.
cat > "$TMP/fake-claude.sh" <<'SH'
#!/bin/bash
idir="$1"; shift
printf '%s\n' "$*" >> "$idir/launches.log"
: > "$idir/handshake-ok"
while IFS= read -r line; do printf '%s\n' "$line" >> "$idir/received.log"; done
SH
# The stand-in for the watchdog: named so that `instance_watchdog_alive` recognises it.
cat > "$TMP/fake-watchdog.sh" <<'SH'
#!/bin/bash
while :; do sleep 1; done
SH
chmod +x "$TMP/fake-claude.sh" "$TMP/fake-watchdog.sh"

make_run() {   # a run parked on Codex, owing its review, with nothing alive
  rm -rf "$IDIR"; mkdir -p "$IDIR"
  printf '%s\n' "$PROJ" > "$IDIR/project"
  printf '%s\n' "$SESSION" > "$IDIR/session"
  printf '%s\n' "$RID" > "$IDIR/run-id"
  printf '%s' "$SID" > "$IDIR/claude-session-id"
  printf 'old-generation\n' > "$IDIR/worker-generation"
  : > "$IDIR/started-at"
  printf '%s\n' "$(shq "$TMP/fake-claude.sh") $(shq "$IDIR") --resume @CLAUDE_SESSION@ --append-system-prompt-file $(shq "$IDIR/standards.md"); true stop --generation @GENERATION@" > "$IDIR/relaunch-template"
  printf '{"provider":"codex","resume_after":%s,"reason":"reviewer unreachable","run_id":"%s"}\n' "$(( $(date +%s) - 120 ))" "$RID" > "$IDIR/paused-for-limit.json"
  printf '{"reason":"the reviewer could not be reached","session_id":"%s"}\n' "$SID" > "$IDIR/review-pending"
  printf '{"stage":"review","run_id":"%s"}\n' "$RID" > "$IDIR/codex-owed.json"
  printf '{"choice":"wait","signature":"sig","run_id":"%s"}\n' "$RID" > "$IDIR/codex-fallback.json"
  printf 'decided things\n' > "$IDIR/decisions.md"
  printf '{"criterion":"a check"}\n' > "$IDIR/checks.jsonl"
  printf '99999\n' > "$IDIR/watchdog.pid"   # a watchdog that is long gone
}
workers() { grep -c . "$IDIR/launches.log" 2>/dev/null || echo 0; }   # Claudes started on this run

echo "===== a dead run that owes work is brought back as it was ====="
make_run
out="$(SUPERVISOR_WATCHDOG_CMD="$TMP/fake-watchdog.sh" "$BIN_DIR/night-shift.sh" revive "$PROJ" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "revive succeeds" || bad "revive failed (rc=$rc): $out"
tmux has-session -t "$SESSION" 2>/dev/null && ok "the session is back" || bad "no session after revive"
[ "$(cat "$IDIR/run-id")" = "$RID" ] && ok "the same run id" || bad "the run id changed: $(cat "$IDIR/run-id" 2>/dev/null)"
for f in paused-for-limit.json review-pending codex-owed.json codex-fallback.json decisions.md checks.jsonl; do
  [ -s "$IDIR/$f" ] && ok "$f kept" || bad "$f was lost"
done
grep -q -- "--resume '$SID'\|--resume $SID" "$IDIR/launches.log" 2>/dev/null && ok "the same Claude conversation, resumed" \
  || bad "not launched as --resume of its conversation: $(cat "$IDIR/launches.log" 2>/dev/null)"
[ "$(cat "$IDIR/worker-generation")" != "old-generation" ] && ok "under a new generation" || bad "the generation was not renewed"
instance_watchdog_alive "$IDIR" "$SLUG" && ok "and a watchdog is watching it again" || bad "no watchdog after revive"
STUB_PIDS="$(cat "$IDIR/watchdog.pid" 2>/dev/null)"
[ "$(workers)" = 1 ] && ok "exactly one Claude started" || bad "$(workers) Claudes started"

echo
echo "===== a second call on a whole run starts nothing ====="
wd_before="$(cat "$IDIR/watchdog.pid")"
SUPERVISOR_WATCHDOG_CMD="$TMP/fake-watchdog.sh" "$BIN_DIR/night-shift.sh" revive "$PROJ" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "revive on a whole run is a no-op success" || bad "revive on a whole run returned $rc"
[ "$(workers)" = 1 ] && ok "still one Claude" || bad "a second Claude was started ($(workers))"
[ "$(cat "$IDIR/watchdog.pid")" = "$wd_before" ] && ok "still the same watchdog" || bad "a second watchdog was started"

echo
echo "===== refused: a Claude on this conversation still running, a stopped run ====="
tmux kill-session -t "$SESSION" 2>/dev/null; kill $STUB_PIDS 2>/dev/null; STUB_PIDS=""
sleep 0.5
make_run
( exec -a "claude --resume $SID --effort xhigh" sleep 30 ) &
held=$!
sleep 0.3
SUPERVISOR_WATCHDOG_CMD="$TMP/fake-watchdog.sh" "$BIN_DIR/night-shift.sh" revive "$PROJ" >/dev/null 2>&1; rc=$?
kill "$held" 2>/dev/null
[ "$rc" = 5 ] && ok "a Claude still running this conversation → not now" || bad "not refused with a live Claude (rc=$rc)"
tmux has-session -t "$SESSION" 2>/dev/null && bad "a second session was started beside it" || ok "no second session started"
make_run; : > "$IDIR/director-stopped"
SUPERVISOR_WATCHDOG_CMD="$TMP/fake-watchdog.sh" "$BIN_DIR/night-shift.sh" revive "$PROJ" >/dev/null 2>&1; rc=$?
[ "$rc" = 4 ] && ok "a run the director stopped → refused" || bad "a stopped run was revived (rc=$rc)"
tmux has-session -t "$SESSION" 2>/dev/null && bad "the stopped run got a session" || ok "and got no session"

echo
echo "===== a message to a dead run that owes work revives it, nothing deleted ====="
make_run
out="$(SUPERVISOR_WATCHDOG_CMD="$TMP/fake-watchdog.sh" SUPERVISOR_ENABLE_RESUME=1 SUPERVISOR_PROMPT_WAIT=3 \
        SUPERVISOR_INJECT_SETTLE=1 SUPERVISOR_INJECT_CALM=1 SUPERVISOR_ENTER_CONFIRM_WAIT=1 SUPERVISOR_INJECT_ENTER_TRIES=1 \
        "$BIN_DIR/worker-send.sh" "$PROJ" "$SID" - "$RID" "Codex is back — carry on" 2>&1)"
[ -d "$IDIR" ] && [ "$(cat "$IDIR/run-id" 2>/dev/null)" = "$RID" ] && ok "the instance and its run id survived the message" \
  || bad "the message replaced the run: $(cat "$IDIR/run-id" 2>/dev/null)"
[ -s "$IDIR/review-pending" ] && [ -s "$IDIR/codex-fallback.json" ] && ok "the owed review and the signed wait are still there" \
  || bad "the owed review or the signed decision went"
tmux has-session -t "$SESSION" 2>/dev/null && ok "the run is alive to take it" || bad "no session after the message"
grep -q "brought back in place" "$SUPERVISOR_STATE_DIR/supervisor.log" && ok "the log says it was brought back in place" \
  || bad "no revival in the log: $out"
case "$out" in *TIER=*) ok "and the message has a tier ($(printf '%s' "$out" | sed -n 's/^TIER=//p' | head -1))" ;;
  *) bad "worker-send gave no tier: $out" ;; esac
STUB_PIDS="$(cat "$IDIR/watchdog.pid" 2>/dev/null)"
tmux kill-session -t "$SESSION" 2>/dev/null; kill $STUB_PIDS 2>/dev/null; STUB_PIDS=""

echo
echo "===== the SessionStart sweep leaves an old run that owes work alone ====="
make_run
touch -t 202001010000 "$IDIR/last-activity" "$IDIR/started-at"
OTHER="$SUPERVISOR_STATE_DIR/instances/old-idle"; mkdir -p "$OTHER"; : > "$OTHER/started-at"
touch -t 202001010000 "$OTHER/started-at"
bash "$HOOKS_DIR/safety-check.sh" </dev/null >/dev/null 2>&1
[ -d "$IDIR" ] && ok "a run parked on a window for days is not swept away" || bad "the sweep deleted a run that owes work"
[ -d "$OTHER" ] && bad "an old run that owes nothing was kept" || ok "one that owes nothing is still swept, as before"

echo
echo "===== a watchdog whose session was killed starts its worker again ====="
make_run
launch="$(sed "s|@CLAUDE_SESSION@|'$SID'|; s|@GENERATION@|g1|" "$IDIR/relaunch-template")"
tmux new-session -d -s "$SESSION" -c "$PROJ" "$launch"
SUPERVISOR_WATCHDOG_POLL=1 SUPERVISOR_REVIVE_GAP=0 nohup "$BIN_DIR/watchdog.sh" "$SLUG" >/dev/null 2>&1 &
wd=$!; printf '%s\n' "$wd" > "$IDIR/watchdog.pid"
sleep 2
tmux kill-session -t "$SESSION" 2>/dev/null
back=0
for _ in $(seq 1 25); do tmux has-session -t "$SESSION" 2>/dev/null && { back=1; break; }; sleep 1; done
[ "$back" = 1 ] && ok "the session came back without anyone asking" || bad "the watchdog left its session dead"
[ "$(cat "$IDIR/run-id" 2>/dev/null)" = "$RID" ] && ok "in place" || bad "not in place"
kill "$wd" 2>/dev/null

echo
[ "$fails" = 0 ] && echo "✅ revive: a run that owes work comes back as it was" || echo "❌ $fails problem(s)"
exit "$fails"
