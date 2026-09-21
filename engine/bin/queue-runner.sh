#!/bin/bash
set -u
BIN_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$BIN_DIR/supervisor-lib.sh"
QDIR="$SUP_STATE/queue"; PEND="$QDIR/pending"; DONE="$QDIR/done"; NEEDS="$QDIR/needs-user"
LOG="$QDIR/runner.log"; STOP_FLAG="$QDIR/stop"; CURRENT="$QDIR/current"
NS="${SUPERVISOR_NS_CMD:-$BIN_DIR/night-shift.sh}"   # overridable for tests
POLL=$SUPERVISOR_QUEUE_POLL                       # from supervisor/config.sh
PROMPT_WAIT=$SUPERVISOR_PROMPT_WAIT               # "
MAX_PROJECT_SECONDS=$SUPERVISOR_MAX_PROJECT_SECONDS   # 8h safety cap (config.sh)
export INJECT_LOG="$LOG"                              # inject_task logs send errors here

log() { echo "$(date '+%F %T') [queue] $*" >> "$LOG"; }
ts() { date +%s; }
rm -f "$STOP_FLAG"
log "runner started (pid $$)"

while :; do
  [ -f "$STOP_FLAG" ] && { log "stop flag set — exiting"; break; }
  entry="$(ls -1d "$PEND"/*/ 2>/dev/null | sort | head -1)"; entry="${entry%/}"
  [ -n "$entry" ] || { log "queue empty — exiting"; break; }

  name="$(basename "$entry")"
  proj="$(cat "$entry/project" 2>/dev/null)"
  task="$(cat "$entry/task" 2>/dev/null)"
  printf '%s\n' "$proj" > "$CURRENT"
  log "▶ project: $proj"

  archive() {  # $1=result (coarse)  $2=optional fine worker-outcome — move the entry out of pending
    local res="$1" fine="${2:-}" base="$DONE"
    case "$res" in needs-user|handoff|blocked) base="$NEEDS" ;; esac
    mkdir -p "$base"
    local dest="$base/${name}-${res}-$(ts)"
    mv "$entry" "$dest" 2>/dev/null && printf '%s\n' "$res" > "$dest/result" 2>/dev/null
    [ -n "$fine" ] && printf '%s\n' "$fine" > "$dest/outcome" 2>/dev/null || true
  }

  if [ ! -d "$proj" ]; then log "dir gone, skipping: $proj"; archive "gone"; continue; fi

  if ! "$NS" start "$proj" --no-attach >>"$LOG" 2>&1; then
    log "night-shift start FAILED: $proj"; archive "startfail"; continue
  fi

  slug="$(slug_for "$proj")"; session="$(session_name "$slug")"; idir="$(instance_dir "$slug")"

  # The queue waits for Codex too.
  #
  # It was carved out of this rule on the reasoning that holding here would stall every project
  # behind one spent window and leave an empty morning. That reasoning is real, and it is not mine
  # to act on: the director said by default nothing runs without Codex, and an exemption I invented
  # is not a default he chose. So the queue holds like every other entry point — and the card gives
  # him the one press that releases it, which is the difference between a policy and a wall.
  #
  # The hold is per project and re-read every poll, so releasing one does not release the rest, and
  # a window that comes back releases all of them without anybody pressing anything.
  _qheld=0
  while [ "${SUPERVISOR_PREFLIGHT_ENABLE:-1}" = 1 ]; do
    _qwhy="$(prep_blocked_reason "$idir" 1 || true)"
    [ -n "$_qwhy" ] || break
    if [ "$_qheld" = 0 ]; then
      log "HOLD $(basename "$proj"): $_qwhy — черга чекає, поки це не зміниться або директор не вирішить"
      [ "$_qwhy" = codex ] && codex_decision_ask "$idir" preparation exhausted \
        "$(provider_state codex | awk '{print $2}')" "$(provider_unavailable_note codex)"
    fi
    [ -f "$STOP_FLAG" ] && { log "queue stopped while holding $(basename "$proj")"; break 2; }
    codex_decision_settle "$idir" >/dev/null 2>&1 || true
    sleep "${SUPERVISOR_QUEUE_HOLD_POLL:-30}"; _qheld=$((_qheld + ${SUPERVISOR_QUEUE_HOLD_POLL:-30}))
  done
  [ "$_qheld" -gt 0 ] && log "held $(basename "$proj") for ${_qheld}s, now preparing"
  codex_decision_close_stage "$idir" preparation >/dev/null 2>&1 || true

  if [ "${SUPERVISOR_PREFLIGHT_ENABLE:-1}" = 1 ] && [ -x "$BIN_DIR/preflight.sh" ]; then
    "$BIN_DIR/preflight.sh" "$proj" "$task" >>"$LOG" 2>&1 || log "WARN: preflight non-zero (degrading to plain task)"
  fi
  # compose_task_prompt points at design.md BEFORE markup and also carries the adaptive-peer
  # alignment plus the unlimited consultation channel. Direct and queued work use one contract.
  aug="$(compose_task_prompt "$idir" "$task")"
  inject_task "$session" "$aug"; ir=$?
  if [ "$ir" = 1 ]; then
    log "ERROR: task injection FAILED (no session) → $session — aborting this project"
    "$NS" stop "$proj" >>"$LOG" 2>&1 || true
    tmux kill-session -t "$session" 2>/dev/null
    archive "injectfail"; continue
  elif [ "$ir" = 2 ]; then
    log "WARN: task injection unconfirmed (pane unchanged) → $session — proceeding, 8h cap is the backstop"
  else
    log "task injected → $session"
  fi

  start_ts=$(ts); result=""
  while [ -z "$result" ]; do
    if [ -f "$idir/done" ]; then result="$(cat "$idir/done" 2>/dev/null || echo passed)"; break; fi
    [ -f "$idir/stalled.json" ] && { result="needs-user"; break; }
    [ -f "$STOP_FLAG" ] && { result="interrupted"; break; }
    [ -d "$idir" ] || { result="vanished"; break; }        # stopped manually
    if [ $(( $(ts) - start_ts )) -ge "$MAX_PROJECT_SECONDS" ]; then result="timeout"; break; fi
    sleep "$POLL"
  done
  log "project finished ($result): $proj"

  fine_outcome="$(jq -r '.result // empty' "$idir/outcome.json" 2>/dev/null || true)"
  "$NS" stop "$proj" >>"$LOG" 2>&1 || true
  tmux kill-session -t "$session" 2>/dev/null   # queue cleans up; don't leave idle sessions
  archive "$result" "$fine_outcome"

  [ "$result" = "interrupted" ] && { log "interrupted — exiting"; break; }
done

rm -f "$CURRENT" "$STOP_FLAG"
log "runner exited"
