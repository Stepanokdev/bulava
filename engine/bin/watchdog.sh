#!/bin/bash
set -u
SLUG="${1:?usage: watchdog.sh <slug>}"
BIN_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$BIN_DIR/supervisor-lib.sh"

IDIR="$(instance_dir "$SLUG")"
SESSION="$(cat "$IDIR/session" 2>/dev/null || session_name "$SLUG")"
PAUSED="$IDIR/paused-for-limit.json"
AWAITING="$IDIR/awaiting-codex"          # intentional pause (question hook waiting on Codex)
LOG="$SUP_STATE/watchdog.log"
POLL=$SUPERVISOR_WATCHDOG_POLL           # from supervisor/config.sh
RESUME_PROMPT="Продовжуй роботу над поточною задачею. Працюй за специфікацією, виконуй усе зі списку повністю, не зрізай кути."
RESUME_NEEDLE="Продовжуй роботу над поточною"
REVIEW_PROMPT="Codex знову доступний, а перевірка твоєї роботи була відкладена через його ліміт. Переконайся, що робота справді завершена, і заверши хід — перевірка відбудеться на ньому."
REVIEW_NEEDLE="Codex знову доступний"
LIMIT_RECHECK_COOLDOWN="${SUPERVISOR_LIMIT_RECHECK_COOLDOWN:-600}"

log() { echo "$(date '+%F %T') [$SLUG] $*" >> "$LOG"; }
log "watchdog started (pid $$, session $SESSION)"
last_resume=$(cat "$IDIR/last-resume" 2>/dev/null || echo 0)
case "$last_resume" in ''|*[!0-9]*) last_resume=0 ;; esac

# Which run this watchdog belongs to. A watchdog outliving its run is not a supervisor of the next
# one: it would flush that run's queue, press Enter at its pane and tell it to carry on with "the
# current task" — a task it has never heard of.
WD_RUN="$(tr -d '[:space:]' < "$IDIR/run-id" 2>/dev/null || true)"

wrong_run() {
  local now_rid
  now_rid="$(tr -d '[:space:]' < "$IDIR/run-id" 2>/dev/null || true)"
  [ -n "$WD_RUN" ] && [ -n "$now_rid" ] && [ "$WD_RUN" != "$now_rid" ]
}

# Who this nudge is FOR, re-read at the last possible moment.
#
# Checking before taking the claim is checking early: taking it can block while somebody else
# finishes a handover, and in that time the work can be superseded. So the question is asked again
# on the far side of the claim, where nothing else can be typing and nothing else can start.
owner_changed() {   # $1=expected run id (may be empty)  $2=expected dispatch id (may be empty)
  local want_run="${1:-}" want_disp="${2:-}" now_run now_disp
  now_run="$(tr -d '[:space:]' < "$IDIR/run-id" 2>/dev/null || true)"
  [ -n "$want_run" ] && [ -n "$now_run" ] && [ "$want_run" != "$now_run" ] && return 0
  now_disp="$(jq -r '.id // empty' "$IDIR/dispatch.json" 2>/dev/null || true)"
  [ -n "$want_disp" ] && [ -n "$now_disp" ] && [ "$want_disp" != "$now_disp" ] && return 0
  return 1
}

send_resume() {   # $1=why  [$2=prompt  $3=needle  $4=expected run id  $5=expected dispatch id]
  local prompt="${2:-$RESUME_PROMPT}" needle="${3:-$RESUME_NEEDLE}"
  local want_run="${4:-}" want_disp="${5:-}"
  # Three processes can decide within the same second that the worker should be given something.
  # Only one of them may be typing — and a resume that loses that race is POSTPONED, never
  # dropped: the marker that asked for it is what the next poll reads, so it comes round again.
  if ! delivery_claim "$IDIR" "watchdog-resume"; then
    log "resume deferred ($1) — another process is handing something over; it stays owed"
    return 1
  fi
  # Past the claim, and therefore past any wait it involved. This is the last instant before
  # anything is typed, and the only one at which the answer cannot go stale underneath us.
  if owner_changed "$want_run" "$want_disp"; then
    delivery_release "$IDIR"
    log "resume abandoned ($1) — the work it belonged to was superseded while waiting for the composer"
    rm -f "$IDIR/resume-pending" 2>/dev/null || true
    return 0
  fi
  if _turn_running "$SESSION"; then
    delivery_release "$IDIR"
    log "resume abandoned ($1) — a turn started while waiting for the composer"
    return 1
  fi
  last_resume=$(date +%s)
  printf '%s\n' "$last_resume" > "$IDIR/last-resume" 2>/dev/null || true
  if resume_worker "$SESSION" "$IDIR" "$prompt" "$needle"; then
    log "RESUMED ($1)"
    delivery_release "$IDIR"; return 0
  fi
  log "resume not accepted ($1) — attempt $(cat "$IDIR/resume-attempts" 2>/dev/null || echo ?)/${SUPERVISOR_RESUME_MAX_ATTEMPTS:-3}, composer left empty"
  delivery_release "$IDIR"
  return 1
}


if [ -n "$SUPERVISOR_IDLE_KILL_SECS" ]; then
  STALE_SECS="$SUPERVISOR_IDLE_KILL_SECS"
else
  STALE_SECS=$(( SUPERVISOR_IDLE_KILL_HOURS * 3600 ))
fi
touch "$IDIR/last-activity"
last_hash=""
last_pause_log=0
# pause_reconcile removes the marker as it decides, so whose limit it WAS has to be read first.
_pause_who=""
pause_provider_before_clear() { printf '%s' "${_pause_who:-claude}"; }
note_activity() {
  touch "$IDIR/last-activity"
  [ -e "$IDIR/resume-refused" ] || rm -f "$IDIR/stalled.json" 2>/dev/null || true
  rm -f "$IDIR/offline.json" 2>/dev/null || true
}

while [ -d "$IDIR" ]; do
  if wrong_run; then
    log "run changed under this watchdog ($WD_RUN → $(tr -d '[:space:]' < "$IDIR/run-id" 2>/dev/null)) — exiting rather than supervising somebody else's work"
    exit 0
  fi
  tmux has-session -t "$SESSION" 2>/dev/null || { sleep "$POLL"; continue; }
  now=$(date +%s)

  if [ -e "$IDIR/offline.json" ] && network_up; then
    rm -f "$IDIR/offline.json" 2>/dev/null || true
    log "network is back — cleared offline state"
  fi

  pane=$(tmux capture-pane -t "$SESSION" -p 2>/dev/null)
  cur_hash=$(printf '%s' "$pane" | cksum)
  if [ "$cur_hash" != "$last_hash" ]; then note_activity; last_hash="$cur_hash"; fi

  # Preparation is work, even though the pane is perfectly still while it happens. Two model calls
  # take minutes; without this the run would be declared stalled and the flush below would type a
  # raw message into a worker whose prepared one is halfway written.
  preparing=0
  if pipeline_running "$IDIR"; then
    preparing=1
    note_activity
  elif [ "$(pending_count "$IDIR")" != 0 ] && tmux has-session -t "$SESSION" 2>/dev/null; then
    case "$(pending_queue_state "$IDIR")" in
      restart)
        # Envelopes with nobody to open them: the pump was killed, or the app was quit mid-send.
        nohup "${SUPERVISOR_PUMP_CMD:-$BIN_DIR/message-pump.sh}" "$SLUG" >/dev/null 2>&1 &
        log "restarted the message pump — $(pending_count "$IDIR") message(s) waiting to be prepared"
        preparing=1
        note_activity ;;
      external)
        # The pump is up and waiting for Codex or a usage window, not for the worker. Nothing the
        # pane could do would change that, so its stillness is not a stall and not a hang.
        preparing=1
        note_activity ;;
      worker)
        # The pump is up and waiting for the WORKER to be free. That wait is decided by the very
        # things the checks below already read — a running turn, an open review, a pause — so
        # nothing is marked here. Marking it was the bug: with one message queued, a worker that
        # took its task and froze read as "preparing" on every poll, for as long as the queue held.
        : ;;
    esac
  fi

  # A consultation still in flight, judged by whether anyone is still waiting on it rather than by
  # the file being there. `awaiting_codex_live` removes the marker itself when nobody is.
  awaiting_active=0
  if awaiting_codex_live "$IDIR"; then
    awaiting_active=1
    note_activity   # keep the idle timer fresh so we never tear down mid-wait
  fi
  # The same for a review whose reviewer has gone: left behind, it held every later message.
  review_active_live "$IDIR" >/dev/null 2>&1 || true

  paused_now=0
  [ -f "$PAUSED" ] && paused_now=1

  # A worker that took its task and froze: a question in its transcript with nothing after it, and a
  # screen that has not changed since. The stall and the teardown below used to be all that ever
  # happened to one — marked, then deleted four hours later with the task still in it. This restarts
  # the process on the same conversation and nudges it, within a fixed budget, and it comes first so
  # that neither of those two fires while it is still trying.
  if [ "$awaiting_active" = 0 ] && [ "$preparing" = 0 ] && [ "$paused_now" = 0 ]; then
    still=$(( now - $(stat -f %m "$IDIR/last-activity" 2>/dev/null || echo "$now") ))
    if hung_turn_check "$IDIR" "$SESSION" "$still" "$WD_RUN"; then
      sleep "$POLL"; continue
    fi
  fi

  # A run parked on a usage window is waiting, not dead. While the pause was one long `sleep` this
  # loop never reached here during one; now that it does, the teardown has to say so itself.
  #
  # And so is a worker parked after a frozen turn — while restarts are still being tried, and after
  # they ran out. Its task is in this directory and nowhere else, and the director's next message is
  # exactly what gets it one more restart (`_hung_due`). Deleting it at the idle deadline is how a
  # task given at three in the morning came back as "continue", a brand-new task with no history.
  if [ "$STALE_SECS" -gt 0 ] && [ "$awaiting_active" = 0 ] && [ "$preparing" = 0 ] \
     && [ "$paused_now" = 0 ] && ! hung_recovery_kept "$IDIR"; then
    idle=$(( now - $(stat -f %m "$IDIR/last-activity" 2>/dev/null || echo "$now") ))
    if [ "$idle" -ge "$STALE_SECS" ]; then
      log "IDLE ${idle}s ≥ ${STALE_SECS}s (screen unchanged) — full teardown: killing claude+tmux, supervision off"
      tmux kill-session -t "$SESSION" 2>/dev/null
      rm -rf "$IDIR"
      _any_instance || rm -f "$SUP_STATE/night-mode"
      exit 0
    fi
  fi

  STALL_PARK_SECS="${SUPERVISOR_STALL_PARK_SECS:-900}"
  # Not while a frozen turn is being recovered: `stalled.json` is terminal to the night queue, and a
  # worker between its first restart and its second is being worked on, not given up on.
  if [ "$STALL_PARK_SECS" -gt 0 ] && [ "$awaiting_active" = 0 ] && [ "$preparing" = 0 ] \
     && [ "$paused_now" = 0 ] && ! hung_recovery_open "$IDIR" \
     && [ ! -e "$IDIR/done" ] && [ ! -e "$IDIR/review-active" ] \
     && [ ! -e "$IDIR/ask-user.json" ] && [ ! -e "$PAUSED" ] && [ ! -e "$IDIR/stalled.json" ]; then
    idle=$(( now - $(stat -f %m "$IDIR/last-activity" 2>/dev/null || echo "$now") ))
    if [ "$idle" -ge "$STALL_PARK_SECS" ] && ! _turn_running "$SESSION"; then
      if ! network_up; then
        if [ ! -e "$IDIR/offline.json" ]; then
          jq -n --arg since "$(date '+%F %T')" --argjson idle "$idle" \
            '{reason:"no network", since:$since, idle_seconds:$idle,
              needs:"nothing — the run resumes by itself when the connection returns"}' \
            > "$IDIR/offline.json" 2>/dev/null || true
          log "OFFLINE after ${idle}s idle — network unreachable, NOT a stall; waiting for it to come back"
        fi
      else
        rm -f "$IDIR/offline.json" 2>/dev/null || true
        jq -n --arg since "$(date '+%F %T')" --argjson idle "$idle" \
          '{reason:"idle at prompt, no declared outcome", since:$since, idle_seconds:$idle}' \
          > "$IDIR/stalled.json" 2>/dev/null || true
        log "STALL ${idle}s ≥ ${STALL_PARK_SECS}s, idle prompt, no outcome/done/question/review — parked (stalled.json), NOT torn down"
      fi
    fi
  fi

  # Whichever window is actually out. Reading the five-hour reset unconditionally meant a run
  # stopped by the WEEKLY window was recorded as coming back in an hour or two, and then woken
  # into the same wall over and over.
  _limit_state="$(provider_state claude)"
  if [ "${_limit_state%% *}" = exhausted ]; then
    resets_at="$(printf '%s' "$_limit_state" | awk '{print $2}')"
  else
    resets_at=$(jq -r '.five_hour.resets_at // 0' "$SUP_STATE/usage.json" 2>/dev/null || echo 0)
  fi
  case "$resets_at" in ''|*[!0-9]*) resets_at=0 ;; esac

  # A pause is re-examined every poll against the live meter and the wall clock, and it is never
  # WAITED OUT.
  #
  # It used to be one `sleep` to the recorded reset time plus ninety seconds. Nothing else in this
  # loop ran while that sleep held: no pump was restarted, no queue was flushed, no session was
  # watched. And the sleep counted only waking seconds, so a Mac that slept through the reset woke
  # with the deadline long past and kept waiting anyway — an hour of a director's message sitting
  # untouched in the queue while the screen said both engines were reading it.

  # A dispatch that was waiting for Codex, and whose waiter is gone.
  #
  # The hold itself is durable because it is written down, not because the process holding it is:
  # `prepare-and-inject.sh` is nohup'ed, and a reboot takes it with everything else. Without this,
  # a task held overnight would simply not exist in the morning. Restarted here, against the same
  # dispatch and the same task file, it picks the wait up where it left off.
  if [ -s "$IDIR/dispatch-held.json" ]; then
    _hd="$(jq -r '.dispatch_id // empty' "$IDIR/dispatch-held.json" 2>/dev/null)"
    _hf="$(jq -r '.taskfile // empty'    "$IDIR/dispatch-held.json" 2>/dev/null)"
    _hp="$(jq -r '.pid // empty'         "$IDIR/dispatch-held.json" 2>/dev/null)"
    case "$_hp" in ''|*[!0-9]*) _hp=0 ;; esac
    if [ "$_hd" != "$(jq -r '.id // empty' "$IDIR/dispatch.json" 2>/dev/null)" ] || [ ! -s "$_hf" ]; then
      rm -f "$IDIR/dispatch-held.json" 2>/dev/null || true
      log "dropped a held dispatch whose work is gone"
    elif [ "$_hp" -gt 0 ] && kill -0 "$_hp" 2>/dev/null; then
      : # its own waiter is alive and doing the waiting
    else
      log "a dispatch was held for Codex and its waiter is gone — picking the wait back up"
      nohup "$BIN_DIR/prepare-and-inject.sh" "$BIN_DIR" "$(cat "$IDIR/project" 2>/dev/null)" \
        "$SESSION" "$SUP_STATE" "$_hf" "$IDIR" "$_hd" >>"$LOG" 2>&1 &
      disown 2>/dev/null || true
    fi
  fi

  # Did the director answer the question about Codex?
  #
  # Read here, above the pause block, and not one line lower: while a pause holds, that block ends
  # the iteration with `continue`. Anything after it is unreachable for exactly as long as the run
  # is parked — which is the entire time the button is on screen. The gate cannot read the answer
  # either, because the gate runs when Claude stops and Claude stopped hours ago. This process is
  # the only one still awake, so this is where a decision becomes a permission: once, and only for
  # the request that is actually open.
  codex_decision_settle "$IDIR" >/dev/null 2>&1 || true

  if [ -f "$PAUSED" ]; then
    _pause_who="$(pause_provider "$IDIR")"
    verdict="$(pause_reconcile "$IDIR")"
    case "$verdict" in
      holds)
        # A wait that keeps renewing itself.
        #
        # The gate asks the director only when the reset it can SEE is a day or more away. A window
        # that comes back in eight hours and is spent again on the hour after would therefore never
        # raise a question — each reading is short, and the run stands still for days with nothing
        # to press. Measured from when the pause was first recorded, that is one wait, and past a
        # day it becomes his to decide however short each individual reading looked.
        if codex_wait_is_his "$IDIR" "$now"; then
          # The old answer was about a wait that has since gone on a whole day longer. It stops
          # standing here rather than silently outliving the question it was given to.
          rm -f "$(codex_grant_file "$IDIR")" 2>/dev/null
          codex_decision_ask "$IDIR" review exhausted \
            "$(provider_state codex | awk '{print $2}')" "$(provider_unavailable_note codex)"
          log "parked on Codex for over a day — the wait is now the director's to end"
        fi
        if [ $(( now - last_pause_log )) -ge 300 ]; then
          log "paused ($(pause_provider "$IDIR")) until $(when_human "$(jq -r '.resume_after // 0' "$PAUSED" 2>/dev/null)") — re-checked against live usage"
          last_pause_log=$now
        fi
        sleep "$POLL"; continue ;;
      cleared-foreign-run|cleared-foreign-work)
        # The pause belonged to work that is over. Resuming from it would type "carry on with the
        # current task" into whatever is being done NOW, which is the failure this fence exists for.
        log "dropped a paused-for-limit marker left behind by earlier work ($verdict) — no resume sent"
        note_activity ;;
      cleared-fresh|attempt)
        # Codex being back does not mean Claude stopped. It means the next consultation and the
        # next review have a reviewer again — and `resume-pending`, written only for Claude's own
        # limits, is what decides below whether anything is actually owed.
        [ "$(pause_provider_before_clear)" = codex ] \
          && log "Codex is available again ($verdict) — Claude was never stopped" \
          || log "Claude's limit lifted ($verdict)"
        note_activity ;;
    esac
  fi

  # What a lifted limit LEFT BEHIND, handled whoever noticed it.
  #
  # The pump reconciles too — it has to, to know whether preparing a message is pointless — so the
  # watchdog is often not the one that removes the marker. When it was not, the work that pause
  # had stopped used to be owed a resume that nobody remembered. The note outlives the marker, and
  # it is only cleared by an injection that actually lands.
  if [ -e "$IDIR/resume-pending" ] && [ ! -f "$PAUSED" ]; then
    _note_rid="$(jq -r '.run_id // empty' "$IDIR/resume-pending" 2>/dev/null)"
    if [ -n "$_note_rid" ] && [ -n "$WD_RUN" ] && [ "$_note_rid" != "$WD_RUN" ]; then
      # The same fence as the pause it came from: a nudge owed to work that is over must not be
      # typed into whatever replaced it.
      rm -f "$IDIR/resume-pending" 2>/dev/null || true
      log "dropped a resume owed to an earlier run"
    elif [ -e "$IDIR/done" ] || [ -e "$IDIR/ask-user.json" ] || [ -e "$IDIR/resume-refused" ]; then
      # Finished, waiting on the director, or already parked for a human to look at. Retrying a
      # nudge the worker has refused three times only re-parks it every poll, for ever.
      rm -f "$IDIR/resume-pending" 2>/dev/null || true
    elif [ -n "$(jq -r '.dispatch_id // empty' "$IDIR/resume-pending" 2>/dev/null)" ] \
         && [ -n "$(jq -r '.id // empty' "$IDIR/dispatch.json" 2>/dev/null)" ] \
         && [ "$(jq -r '.dispatch_id // empty' "$IDIR/resume-pending" 2>/dev/null)" \
              != "$(jq -r '.id // empty' "$IDIR/dispatch.json" 2>/dev/null)" ]; then
      # Asked again immediately before acting, not only when the note was written: the work this
      # nudge belongs to can be superseded while the note sits here waiting for an idle pane.
      rm -f "$IDIR/resume-pending" 2>/dev/null || true
      log "dropped a resume owed to work that has since been superseded"
    elif [ $(( now - last_resume )) -lt "$LIMIT_RECHECK_COOLDOWN" ]; then
      : # one attempt per cooldown, not one per poll
    elif [ "$(pending_count "$IDIR")" != 0 ] || [ -s "$(undelivered_file "$IDIR")" ] \
         || [ -s "$IDIR/undelivered.jsonl" ]; then
      # Something the director actually said is already on its way. That continues the work far
      # better than a generic nudge, and two of them would arrive one inside the other.
      rm -f "$IDIR/resume-pending" 2>/dev/null || true
      log "limit lifted — a queued message will carry the work on, no nudge sent"
    elif ! _turn_running "$SESSION" && [ "$preparing" = 0 ]; then
      if send_resume "limit lifted, work was owed a resume" "" "" \
           "$(jq -r '.run_id // empty' "$IDIR/resume-pending" 2>/dev/null)" \
           "$(jq -r '.dispatch_id // empty' "$IDIR/resume-pending" 2>/dev/null)"; then
        rm -f "$IDIR/resume-pending" 2>/dev/null || true
      fi
      note_activity
    fi
  fi

  # A review that a Codex window interrupted. Claude was allowed to stop; without this the run
  # would end up looking reviewed when nothing ever reviewed it.
  if [ -e "$IDIR/review-pending" ] && [ ! -f "$PAUSED" ] && [ "$preparing" = 0 ] \
     && [ "$(pending_count "$IDIR")" = 0 ] && ! _turn_running "$SESSION" \
     && ! review_active_live "$IDIR"; then
    if { [ -e "$IDIR/resume-refused" ] || [ -e "$IDIR/ask-user.json" ]; } \
         && [ -z "$(codex_fallback_choice "$IDIR" 2>/dev/null || true)" ]; then
      rm -f "$IDIR/review-pending" 2>/dev/null || true
      log "a review was owed, but the worker will not take a resume — left for a person"
    elif [ -e "$IDIR/resume-refused" ] || [ -e "$IDIR/ask-user.json" ]; then
      # Something else is holding the worker, and the director has already said how the review
      # should happen. Throwing the debt away here would quietly discard a decision he made: the
      # obstacle in front of it is temporary, and the review is still owed behind it.
      :
    elif [ $(( now - last_resume )) -lt "$LIMIT_RECHECK_COOLDOWN" ]; then
      : # one attempt per cooldown
    elif [ "$(codex_fallback_choice "$IDIR" 2>/dev/null || true)" = claude ]; then
      # He decided not to wait. The review is still owed — it is the REVIEWER that changed, not the
      # requirement — so the worker is resumed exactly as it would be for a Codex that came back.
      send_resume "the director chose Claude in Codex's place and a review was still owed" \
        "$REVIEW_PROMPT" "$REVIEW_NEEDLE" \
        "$WD_RUN" "$(jq -r '.id // empty' "$IDIR/dispatch.json" 2>/dev/null)"
      note_activity
    elif ! provider_exhausted codex; then
      _owed="$(codex_unanswered_consultations "$IDIR" 2>/dev/null || true)"
      if [ -n "$_owed" ]; then
        # He was asked these and never answered — the calls were declined for want of window, not
        # refused on the merits. Handing them back with the resume is the difference between a
        # consultation that was deferred and one that quietly never happened.
        send_resume "codex is back and a review was still owed" \
          "$REVIEW_PROMPT

Крім того, ці питання ти ставив Codex, і він на них не відповів — постав їх знову, перш ніж завершувати:
$_owed" "$REVIEW_NEEDLE" \
          "$WD_RUN" "$(jq -r '.id // empty' "$IDIR/dispatch.json" 2>/dev/null)"
        note_activity
        sleep "$POLL"; continue
      fi
      # Not "available" — NOT EXHAUSTED. A meter that cannot be read is not a reason to leave work
      # unreviewed for ever: Codex itself may be perfectly fine, and the attempt is the better
      # test. This is the same rule the peer stage and the consultations follow, and leaving it
      # out here meant a telemetry outage could quietly end a run as though it had been checked.
      #
      # The marker is NOT cleared here either. Delivering a prompt is not the same as a review
      # happening, and `resume_worker` reports success merely for seeing a turn running. The
      # review gate removes it when it actually reaches the reviewer; until then this asks again,
      # once per cooldown, and stops for good if the worker refuses.
      send_resume "codex is back and a review was still owed" "$REVIEW_PROMPT" "$REVIEW_NEEDLE" \
        "$WD_RUN" "$(jq -r '.id // empty' "$IDIR/dispatch.json" 2>/dev/null)"
      note_activity
    fi
  fi

  # And never into a worker that still owes an answer to what it was last given. A screen that
  # accepts no typing and a transcript with an open question are the same frozen process; typing a
  # parked message into it is how the prepared task was retyped three times and then written off.
  # A worker restarted since that question was asked owes it nothing, and this is exactly the
  # message that should reach it — the frozen-turn recovery holds its nudge back for it.
  if { [ -s "$(undelivered_file "$IDIR")" ] || [ -s "$IDIR/undelivered.jsonl" ]; } \
     && [ ! -f "$PAUSED" ] && [ "$preparing" = 0 ] && ! _turn_running "$SESSION" \
     && ! worker_owes_answer "$SESSION" "$IDIR"; then
    if delivery_claim "$IDIR" "watchdog-flush"; then
      if flush_undelivered "$SESSION" "$IDIR"; then
        log "delivered a parked message that a usage limit had blocked"
        note_activity 2>/dev/null || true
        delivery_release "$IDIR"
        sleep "$POLL"; continue
      fi
      delivery_release "$IDIR"
    fi
  fi

  pane_tail="$(printf '%s' "$pane" | tail -12)"
  # Our own status bar is not evidence of anything.
  #
  # statusline.sh renders "| 5h: 9% (reset 01:40) | 7d: 10%" into this very pane, and the detector
  # below used to accept "reset 0" as a limit — so a run with nine per cent of its window used was
  # recorded as out of quota, and its queue stopped. The FRAGMENT is removed rather than the line,
  # because a real error can be rendered on the same line as the status bar.
  pane_probe="$(printf '%s' "$pane_tail" | limit_strip_status)"
  limit_class=""
  if printf '%s' "$pane_probe" | grep -qiE "$LIMIT_EXPLICIT"; then
    limit_class=explicit
  elif printf '%s' "$pane_probe" | grep -qiE "$LIMIT_AMBIGUOUS" && provider_exhausted claude; then
    # A reset time on its own says when a window ENDS, not that it is full — the two are told
    # apart by the meter, never by the sentence. With no positive reading that Claude is out,
    # text like this is left alone.
    limit_class=ambiguous-confirmed
  fi
  if [ ! -f "$PAUSED" ] \
     && [ $(( now - last_resume )) -ge "$LIMIT_RECHECK_COOLDOWN" ] \
     && ! _turn_running "$SESSION" \
     && [ -n "$limit_class" ]; then
    log "usage-limit state detected in pane ($limit_class): $(limit_matched_line "$pane_probe")"
    # The dialog, not the words. Claude Code offers "Stop and wait for limit to reset" as a
    # selectable action, and Enter takes it; sending Enter because some line elsewhere in the pane
    # says "enter to confirm" answers whatever question is actually on screen. The pane is read
    # AGAIN here — the capture above is seconds old, and a turn can have started inside them.
    if printf '%s' "$pane_probe" | limit_dialog_present \
       && tmux capture-pane -p -t "$SESSION" 2>/dev/null | limit_dialog_present; then
      tmux send-keys -t "$SESSION" Enter 2>>"$LOG" && log "selected 'Stop and wait for limit to reset' (Enter)"
    fi
    rm -f "$IDIR/stalled.json" 2>/dev/null || true   # it's paused-for-limit, NOT stalled
    # The pane is CLAUDE's, so this is always Claude's limit — and it is recorded as belonging to
    # this run and this piece of work, which is what lets a later reader tell it from a leftover.
    pause_record "$IDIR" claude "$resets_at" "usage limit seen in the worker pane" \
      "$(cat "$IDIR/claude-session-id" 2>/dev/null || true)"
    log "marked paused-for-limit (claude, resume after $(when_human "$(jq -r '.resume_after // 0' "$PAUSED" 2>/dev/null)"))"
    sleep "$POLL"; continue
  fi
  sleep "$POLL"
done
log "instance gone — watchdog exiting"
