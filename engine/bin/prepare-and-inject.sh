#!/bin/bash
# The night dispatcher's half of the same pipeline the chat uses.
#
# It owns the dispatch record (dispatch.sh allocated the report folder against that id), so it
# hands the runner an envelope naming it, and the runner reuses it rather than writing its own.
# The serialisation and the supersede rule stay here because they are dispatch's rules: a newer
# task replaces the one still thinking, which is right for a night queue and wrong for a
# conversation — a chat message is never thrown away because the next one arrived.
set -u
BIN_DIR="${1:?}"; PROJ="${2:?}"; SESSION="${3:?}"; STATE="${4:?}"; TASKFILE="${5:?}"; IDIR="${6:?}"; DISPATCH_ID="${7:?}"
. "$BIN_DIR/supervisor-lib.sh"
export INJECT_LOG="$STATE/supervisor.log"
ENVELOPE="$IDIR/.dispatch-envelope-$DISPATCH_ID.json"
cleanup() { rm -f "$TASKFILE" "$TASKFILE.composed" "$ENVELOPE" "$IDIR/dispatch-held.json"; }
trap cleanup EXIT

# Serialization lives in the runner now, and it covers the chat as well as the dispatcher — two
# locks in two scripts was the same as no lock at all, because they were different locks. What is
# left here is the dispatcher's own rule: a newer dispatch supersedes this one, checked before the
# work starts and again inside the runner right before anything is injected.
current="$(jq -r '.id // empty' "$IDIR/dispatch.json" 2>/dev/null || true)"
[ "$current" = "$DISPATCH_ID" ] || { echo "$(date '+%F %T') [dispatch] stale $DISPATCH_ID skipped before preflight" >> "$STATE/supervisor.log"; exit 0; }
task="$(cat "$TASKFILE")"

rid=""; [ -r "$IDIR/run-id" ] && rid="$(tr -d '[:space:]' < "$IDIR/run-id")"
pipeline="plain"
if [ "${SUPERVISOR_PREFLIGHT_ENABLE:-1}" = 1 ] && [ -x "$BIN_DIR/preflight.sh" ]; then
  case "${SUPERVISOR_COLLABORATION_MODE:-adaptive_peer}" in
    adaptive_peer) pipeline="dispatch" ;;
    *)             pipeline="dispatch-legacy" ;;
  esac
fi

# The same hold the chat pump applies, on the other entry point into the same preparation.
#
# A dispatch from the app is a person sitting in front of it, so "by default nothing runs without
# Codex" means exactly that: the task waits here, whole, with a card giving the one press that
# overrides it.
#
# There is deliberately NO cap. The first version gave up after eight hours and prepared anyway —
# an automatic bypass, which is the whole class of behaviour this change exists to remove, and it
# was worst in the case it was least excusable: an incompatible Stop hook, where carrying on means
# building a night on a guarantee that is not installed. The hold ends when the reason ends, when
# the director answers, or when the work it belongs to is replaced. Nothing else ends it.
#
# The night QUEUE is deliberately not held this way. Holding there would stall every project behind
# one spent window and the morning would be empty, while preparing and parking at the review still
# guarantees that nothing FINISHES without Codex — the promise that matters unattended.
_needs_codex=0
case "$pipeline" in dispatch|adaptive-peer) _needs_codex=1 ;; esac
HELD="$IDIR/dispatch-held.json"
_held=0
while [ "$_needs_codex" = 1 ]; do
  _why="$(prep_blocked_reason "$IDIR" 1 || true)"
  [ -n "$_why" ] || break
  # Written down, and kept up to date, because this process is not the durable part. It is
  # `nohup`ed rather than immortal: a reboot takes it with everything else, and without a record
  # the director's task would be gone with it. The watchdog restarts a hold whose holder died.
  jq -n --arg d "$DISPATCH_ID" --arg t "$TASKFILE" --arg w "$_why" --argjson pid "$$" \
     --argjson at "$(date +%s)" \
     '{dispatch_id:$d, taskfile:$t, reason:$w, pid:$pid, at:$at}' > "$HELD.tmp" 2>/dev/null \
    && mv -f "$HELD.tmp" "$HELD" 2>/dev/null
  if [ "$_held" = 0 ]; then
    echo "$(date '+%F %T') [dispatch] $DISPATCH_ID holding: $_why" >> "$STATE/supervisor.log"
    [ "$_why" = codex ] && codex_decision_ask "$IDIR" preparation exhausted \
      "$(provider_state codex | awk '{print $2}')" "$(provider_unavailable_note codex)"
  fi
  # Superseded, withdrawn, or the run torn down underneath the wait — all three end it, and none
  # of them should end with a task being injected.
  [ -d "$IDIR" ] || { rm -f "$HELD" 2>/dev/null; exit 0; }
  if [ "$(jq -r '.id // empty' "$IDIR/dispatch.json" 2>/dev/null)" != "$DISPATCH_ID" ]; then
    rm -f "$HELD" 2>/dev/null; exit 0
  fi
  codex_decision_settle "$IDIR" >/dev/null 2>&1 || true
  sleep "${SUPERVISOR_PREP_HOLD_POLL:-10}"; _held=$((_held + ${SUPERVISOR_PREP_HOLD_POLL:-10}))
done
rm -f "$HELD" 2>/dev/null || true
# The hold is over, so the question about it is. Preparation records no pause, so nothing else
# withdraws this one — and a card still asking whether to wait, while the task is being prepared,
# is a decision about nothing. A late answer then finds no open request and grants nothing.
codex_decision_close_stage "$IDIR" preparation >/dev/null 2>&1 || true
[ "$_held" -gt 0 ] && echo "$(date '+%F %T') [dispatch] $DISPATCH_ID held ${_held}s, now preparing" \
  >> "$STATE/supervisor.log"

jq -nc --arg m "$task" --arg rid "$rid" --arg p "$pipeline" --arg d "$DISPATCH_ID" \
   --arg seq "dispatch" --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
   '{seq:$seq, at:$at, pipeline:$p, intent:"conversation", message:$m,
     dispatch_id:$d, guard_dispatch:$d}
    + (if $rid == "" then {} else {run_id:$rid} end)' > "$ENVELOPE" 2>/dev/null \
  || { echo "$(date '+%F %T') [dispatch] could not build an envelope for $DISPATCH_ID" >> "$STATE/supervisor.log"; exit 1; }

"$BIN_DIR/pipeline.sh" "$IDIR" "$ENVELOPE"; rc=$?
[ "$rc" = 7 ] && rc=0          # superseded before injection — the newer dispatch owns the session
exit "$rc"
