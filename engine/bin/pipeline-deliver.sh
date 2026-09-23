#!/bin/bash
# Stage: hand the composed prompt to the worker.
#
# The last thing before the worker reads anything, so it is also the last chance to notice that the
# message was taken back or that the run it belonged to is gone. Injection that does not confirm a
# turn is parked in the engine's existing retry queue — already composed, so the watchdog's flush
# delivers a prepared prompt rather than a raw one.
set -u
SELF="${BASH_SOURCE[0]}"; while [ -L "$SELF" ]; do d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac; done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"
. "$BIN_DIR/supervisor-lib.sh"

ART=""
while [ $# -gt 0 ]; do
  case "${1:-}" in --art) ART="${2:-}"; shift 2 ;; *) break ;; esac
done
PROJ="${1:?usage: pipeline-deliver.sh --art DIR <project> <task...>}"; shift
TASK="$*"
IDIR="${PIPE_IDIR:?pipeline-deliver.sh runs as a pipeline stage}"
SESSION="${PIPE_SESSION:?}"
MSG_ID="${PIPE_MESSAGE_ID:-}"
[ -n "$ART" ] || ART="${PIPE_ART:-$IDIR}"
run_env_load "$IDIR"
LOG="$SUP_STATE/supervisor.log"
export INJECT_LOG="$LOG"

PROMPT="$(cat "$ART/composed.txt" 2>/dev/null)"
[ -n "$PROMPT" ] || PROMPT="$TASK"

# The last possible moment, and the one that matters most: everything before this can be redone,
# and this cannot. A message the director took back while the prompt was being composed must not
# arrive a second later because the check happened a stage too early.
if [ -n "$MSG_ID" ] && message_cancelled "$IDIR" "$MSG_ID"; then
  echo "$(date '+%F %T') [pipeline] message $MSG_ID was taken back — not injecting" >> "$LOG"
  exit 7
fi

# And the check alone is not enough, because the handoff itself takes time: waiting for a prompt,
# pasting, pressing Enter. A withdrawal arriving inside that used to be told "withdrawn" while the
# text was already in the composer. So the handoff says where it is, under this run's own name, and
# whoever wants the message back reads that instead of guessing.
# The trail belongs to the MESSAGE, not to the process that happened to carry it: it is how the
# sequence of a particular handoff can be read back afterwards, including one that failed or was
# taken back. `stages.jsonl` says the delivery stage took six seconds; this says what happened
# inside those six seconds and when.
PHASE="$ART/handoff"
: > "$PHASE.log" 2>/dev/null || true
printf 'waiting\n' > "$PHASE" 2>/dev/null || true
jq -nc --arg m "${MSG_ID:-}" --argjson pid "$$" --arg p "$PHASE" --arg s "$SESSION" \
   --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
   '{pid:$pid, phase_file:$p, session:$s, at:$at}
    + (if $m == "" then {} else {message_id:$m} end)' > "$(delivering_file "$IDIR").tmp" 2>/dev/null \
  && mv -f "$(delivering_file "$IDIR").tmp" "$(delivering_file "$IDIR")" 2>/dev/null
# The live marker goes; the trail stays with the message's other artifacts.
cleanup_handoff() { rm -f "$(delivering_file "$IDIR")" "$PHASE" "$PHASE.tmp" 2>/dev/null || true; }
trap cleanup_handoff EXIT

rm -f "$IDIR/inject-failed" 2>/dev/null || true
# Only one process may be typing at the composer. The watchdog's resume and the retry queue's
# flush take the same claim, so a limit lifting at the moment a prepared message is handed over
# cannot put a nudge halfway through it.
if delivery_claim "$IDIR" "pipeline-deliver"; then
  trap 'delivery_release "$IDIR"; cleanup_handoff' EXIT
else
  echo "$(date '+%F %T') [pipeline] composer is busy with another handover — parking the prepared prompt" >> "$LOG"
  park_undelivered "$IDIR" "$PROMPT" "$MSG_ID"
  exit 0
fi
# The same seam the watchdog and the launcher already have, for the same reason: the suite needs to
# assert WHAT was handed over and WHEN, and typing into a real pane is proved by its own tests.
if [ -n "${SUPERVISOR_INJECT_CMD:-}" ]; then
  INJECT_PHASE_FILE="$PHASE" "$SUPERVISOR_INJECT_CMD" "$SESSION" "$ART/composed.txt"; rc=$?
else
  INJECT_PHASE_FILE="$PHASE" INJECT_IDIR="$IDIR" inject_task "$SESSION" "$PROMPT"; rc=$?
fi
echo "$(date '+%F %T') [pipeline] inject rc=$rc → $SESSION" >> "$LOG"
case "$rc" in
  0)
    # Committed. From here a withdrawal can only honestly answer "already read".
    printf '%s outcome=delivered\n' "$(date '+%F %T.000')" >> "$PHASE.log" 2>/dev/null || true
    [ -n "$MSG_ID" ] && { mark_delivered "$IDIR" "$MSG_ID"; thread_delivered "$IDIR" "$MSG_ID"; }
    # The director's own words just continued the work. A generic "carry on" behind them would
    # arrive as a second message about nothing.
    rm -f "$IDIR/resume-pending" "$IDIR/director-stopped" 2>/dev/null || true
    cleanup_handoff
    [ -n "$MSG_ID" ] && reset_review_budget "$IDIR"
    journal_event "$IDIR" dispatch-delivered "$(printf '%s' "$TASK" | clip_utf8 160)" \
      "$(jq -nc --arg p "${PIPE_PIPELINE:-plain}" '{source:"pipeline", pipeline:$p}')"
    exit 0 ;;
  *)
    # Composed, but the composer would not take it — a usage limit, a busy pane. The engine already
    # owns that problem; give it the PREPARED text so nothing raw can reach the worker later.
    #
    # Unless the reason it would not go is that the director took it back mid-handoff: parking it
    # then would mean the watchdog delivering a withdrawn message minutes later.
    if [ -n "$MSG_ID" ] && message_cancelled "$IDIR" "$MSG_ID"; then
      printf '%s outcome=withdrawn\n' "$(date '+%F %T.000')" >> "$PHASE.log" 2>/dev/null || true
      thread_cancelled "$IDIR" "$MSG_ID"
      cleanup_handoff
      echo "$(date '+%F %T') [pipeline] handoff of $MSG_ID stopped by a withdrawal — not parked" >> "$LOG"
      exit 7
    fi
    printf '%s outcome=parked rc=%s\n' "$(date '+%F %T.000')" "$rc" >> "$PHASE.log" 2>/dev/null || true
    cleanup_handoff
    park_undelivered "$IDIR" "$PROMPT" "$MSG_ID"
    jq -nc --arg at "$(date '+%F %T')" --argjson rc "$rc" --arg s "$SESSION" --arg d "${PIPE_DISPATCH_ID:-}" \
      '{reason:(if $rc == 2 then "задачу надруковано, але воркер її не прийняв — у його журналі її немає" else "задача не дійшла до воркера" end), rc:$rc, session:$s, dispatch:$d, at:$at}' \
      > "$IDIR/inject-failed" 2>/dev/null || true
    journal_event "$IDIR" inject-failed "rc=$rc" '{"source":"pipeline"}'
    echo "$(date '+%F %T') [pipeline] parked the COMPOSED prompt for retry (rc=$rc)" >> "$LOG"
    exit 0 ;;
esac
