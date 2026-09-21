#!/bin/bash
# One pump per project: take prepared messages off the queue, in order, and never more than one.
#
# It exists because preparation takes minutes and delivery takes seconds. Without something that
# owns both, the app either blocks a send for the length of two model calls (it cannot — the call
# times out at 150s) or the message is handed to the worker raw while its briefs are still being
# written, which is exactly the bug this replaces.
#
# The pump waits for the worker to be genuinely idle BEFORE it starts researching. Two positions
# formed against a tree the previous turn is still editing would be two positions about different
# repositories.
set -u
SELF="${BASH_SOURCE[0]}"; while [ -L "$SELF" ]; do d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac; done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"
. "$BIN_DIR/supervisor-lib.sh"

SLUG="${1:?usage: message-pump.sh <slug>}"
IDIR="$(instance_dir "$SLUG")"
[ -d "$IDIR" ] || exit 0
run_env_load "$IDIR"
SESSION="$(cat "$IDIR/session" 2>/dev/null || session_name "$SLUG")"
LOG="$SUP_STATE/supervisor.log"
log() { echo "$(date '+%F %T') [pump/$SLUG] $*" >> "$LOG"; }

LOCK="$IDIR/pump.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  owner="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then exit 0; fi   # somebody is already pumping
  rm -rf "$LOCK" 2>/dev/null || true
  mkdir "$LOCK" 2>/dev/null || exit 0
fi
printf '%s\n' "$$" > "$LOCK/pid"
cleanup() {
  rm -f "$(pipeline_active_file "$IDIR")" "$IDIR/queue-wait.json" 2>/dev/null || true
  rm -rf "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

POLL="${SUPERVISOR_PUMP_POLL:-5}"
MAX_WAIT="${SUPERVISOR_PUMP_IDLE_WAIT:-28800}"

# Idle means the WORKER is not mid-turn, not being reviewed, and not out of its own window.
#
# Every clause here used to be "a file exists", and three of them were wrong for the same reason:
# a marker is written by whoever was waiting at the time and never removed by anybody if that
# process dies, sleeps through its deadline, or was waiting on something else entirely.
#
#   paused-for-limit  belonged to EITHER engine. Codex filling its window during a review made
#                     Claude — perfectly free — unable to be handed the next message at all. It is
#                     now asked whose limit it is, and re-checked against the live meter.
#   awaiting-codex    is a consultation, which runs INSIDE a Claude turn: `_turn_running` already
#                     covers the real case, and the marker only ever added a way to be stuck for
#                     five and a half hours after the consultation itself had gone.
#   review-active     had no owner and no timeout, so a Codex that died mid-review held the queue
#                     until someone noticed.
PREP_NEEDS_CODEX=0

worker_free() {
  review_active_live "$IDIR" && return 1
  pause_blocks_worker "$IDIR" && return 1
  prep_blocked_reason "$IDIR" "$PREP_NEEDS_CODEX" >/dev/null && return 1
  # A night dispatch preparing for the same worker holds the run even though the pane is idle —
  # nothing has been typed at it yet. Claiming a message now would only mean blocking on the
  # runner's lock with a message already taken off the queue.
  pipeline_lock_held "$IDIR" && return 1
  _turn_running "$SESSION" && return 1
  return 0
}

# What the worker is waiting FOR, so the app can say so instead of claiming both engines are
# reading a message that has not reached either of them.
wait_reason() {
  review_active_live "$IDIR" && { printf 'review'; return 0; }
  pause_blocks_worker "$IDIR" && { printf 'limit'; return 0; }
  _blocked="$(prep_blocked_reason "$IDIR" "$PREP_NEEDS_CODEX" || true)"
  [ -n "$_blocked" ] && { printf '%s' "$_blocked"; return 0; }
  pipeline_lock_held "$IDIR" && { printf 'another-message'; return 0; }
  _turn_running "$SESSION" && { printf 'turn'; return 0; }
  printf 'none'
}

publish_wait() {   # $1=reason $2=seq $3=message id
  local f="$IDIR/queue-wait.json"
  if [ "${1:-none}" = none ]; then rm -f "$f" 2>/dev/null; return 0; fi
  jq -nc --arg r "$1" --arg seq "$2" --arg m "${3:-}" --argjson at "$(date +%s)" \
     --argjson until "$(jq -r '.resume_after // 0' "$(pause_file "$IDIR")" 2>/dev/null || echo 0)" \
     '{reason:$r, seq:$seq, since:$at} + (if $m == "" then {} else {message_id:$m} end)
      + (if $until > 0 then {resume_after:$until} else {} end)' > "$f.tmp" 2>/dev/null \
    && mv -f "$f.tmp" "$f" 2>/dev/null || rm -f "$f.tmp" 2>/dev/null
  return 0
}

log "started (pid $$)"
# A message that arrives in the instant between "the queue is empty" and "this pump has released
# its lock" would find a live lock, decline to start a second pump, and then sit there until the
# watchdog noticed it — up to a poll interval of silence for no reason at all. So an empty queue is
# confirmed twice, a beat apart, before this pump goes away.
next_envelope() {
  local f
  f="$(pending_head "$IDIR")" && { printf '%s' "$f"; return 0; }
  sleep "${SUPERVISOR_PUMP_GRACE:-2}"
  f="$(pending_head "$IDIR")" && { printf '%s' "$f"; return 0; }
  return 1
}

while :; do
  # The run can be torn down while this pump is alive — stopping a run removes its whole folder,
  # and the pump is deliberately detached so that closing the app does not interrupt a preparation
  # already under way. Detached is not immortal: with the folder gone there is nothing to prepare
  # and nobody to deliver to.
  [ -d "$IDIR" ] || { log "the run is gone — nothing left to prepare"; break; }
  env_file="$(next_envelope)" || break
  [ -n "$env_file" ] && [ -s "$env_file" ] || { rm -f "$env_file" 2>/dev/null; continue; }
  mid="$(jq -r '.message_id // empty' "$env_file" 2>/dev/null)"
  seq="$(jq -r '.seq // "?"' "$env_file" 2>/dev/null)"

  # Asked BEFORE anything is claimed. A message withdrawn while it sat in the queue must never
  # become work — and the marker is written before the envelope is removed, so this catches it
  # even if the removal has not happened yet.
  if [ -n "$mid" ] && message_cancelled "$IDIR" "$mid"; then
    log "message $seq was taken back before preparation began"
    rm -f "$env_file" 2>/dev/null || true
    thread_cancelled "$IDIR" "$mid"
    clear_cancel "$IDIR" "$mid"
    continue
  fi

  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    log "session $SESSION is gone — leaving message $seq queued for whoever revives it"
    break
  fi

  PREP_NEEDS_CODEX=0
  codex_needed_for "$env_file" && PREP_NEEDS_CODEX=1

  waited=0
  last_why=""
  until worker_free; do
    why="$(wait_reason)"
    if [ "$why" != "$last_why" ]; then
      publish_wait "$why" "$seq" "$mid"
      log "message $seq is waiting: $why"
      last_why="$why"
      # A hold nobody can see or end is a freeze. Whichever of the two it is, the app gets
      # something to show and — for the Codex one — something to press.
      case "$why" in
        codex) codex_decision_ask "$IDIR" preparation exhausted \
                 "$(provider_state codex | awk '{print $2}')" \
                 "$(provider_unavailable_note codex)" ;;
        engine-mismatch) journal_event "$IDIR" engine-mismatch "$(engine_protocol_gap || true)" \
                           '{"source":"pump"}' 2>/dev/null || true ;;
      esac
    fi
    if [ "$waited" -ge "$MAX_WAIT" ]; then
      log "message $seq: gave up waiting ${waited}s for an idle worker — it stays queued"
      break
    fi
    # Taken back while it waited: nothing to prepare. And the same for the whole run going away
    # underneath a wait that is allowed to last hours.
    [ -s "$env_file" ] || break
    [ -d "$IDIR" ] || { log "the run went away while message $seq waited"; break 2; }
    [ -n "$mid" ] && message_cancelled "$IDIR" "$mid" && break
    # Read here as well as in the watchdog. The watchdog polls every forty-five seconds; this loop
    # every five, and it is the one holding the message he is waiting on — so the press that ends
    # the hold ends it now rather than on the minute.
    codex_decision_settle "$IDIR" >/dev/null 2>&1 || true
    sleep "$POLL"; waited=$((waited + POLL))
  done
  publish_wait none "$seq" "$mid"
  # Whatever held this message is over, so the question about it is too. Left standing, it would
  # ask whether to wait for a Codex that is already reading — and a late answer to it now finds
  # nothing open, which is how a stale press comes to nothing.
  codex_decision_close_stage "$IDIR" preparation >/dev/null 2>&1 || true
  if [ ! -s "$env_file" ]; then log "message $seq withdrawn while queued"; continue; fi
  if [ -n "$mid" ] && message_cancelled "$IDIR" "$mid"; then
    log "message $seq taken back while it waited for the worker"
    rm -f "$env_file" 2>/dev/null || true
    thread_cancelled "$IDIR" "$mid"
    clear_cancel "$IDIR" "$mid"
    continue
  fi
  worker_free || { log "message $seq still waiting — pump exits, the watchdog will start it again"; break; }

  log "preparing message $seq (${mid:-no id}) after ${waited}s wait"
  "$BIN_DIR/pipeline.sh" "$IDIR" "$env_file"; rc=$?
  # Cancelled from outside: the pipeline was killed mid-stage rather than reaching its own check.
  [ -n "${mid:-}" ] && message_cancelled "$IDIR" "$mid" && rc=7
  case "$rc" in
    0) log "message $seq delivered" ;;
    # 143/137: the pipeline was killed rather than reaching its own cancellation check — Stop, or
    # a withdrawal on a message that carried no id. Either way the director asked for it to end.
    7|143|137) log "message $seq withdrawn during preparation — nothing was injected"
       [ -n "${mid:-}" ] && thread_cancelled "$IDIR" "$mid" ;;
    *) # A required stage broke in a way composition could not absorb. Losing the director's words
       # is the one outcome worse than an unprepared delivery, so it goes into the retry queue and
       # the log says plainly that it will arrive without its briefs.
       log "message $seq: pipeline failed (exit $rc) — parking the ORIGINAL message unprepared so it is not lost"
       park_undelivered "$IDIR" "$(jq -r '.message // empty' "$env_file" 2>/dev/null)" "$mid" ;;
  esac
  rm -f "$env_file" 2>/dev/null || true
  [ -n "${mid:-}" ] && clear_cancel "$IDIR" "$mid"
  rm -f "$(pipeline_active_file "$IDIR")" 2>/dev/null || true
done
log "nothing left to prepare — exiting"
exit 0
