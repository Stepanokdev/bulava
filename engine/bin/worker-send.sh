#!/bin/bash
set -u
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac; done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"
. "$BIN_DIR/supervisor-lib.sh"
# Kept whole for a second pass after a run is brought back in place (below).
WS_ARGS=("$@")

MODE="conversation"
MESSAGE_ID=""
# Which pipeline this message goes through. `plain` is what the engine has always done: compose the
# standing sections and type it in. It stays the default deliberately — this script also carries
# the foreman's relays and the report runs, and none of those should start paying for two research
# calls because a chat setting changed.
PIPELINE="plain"
# A bridge's own: which task this message belongs to and what it is to it. On a server these are
# required, and the heuristic that guesses "new or follow-up" from the text is not consulted at all.
TASK_ID=""; RELATION=""; SOURCE=""; AUTHOR=""; ANSWERS=""
while [ $# -gt 0 ]; do
  case "${1:-}" in
    --mode) MODE="${2:-conversation}"; shift 2 ;;
    --message-id) MESSAGE_ID="${2:-}"; shift 2 ;;
    --pipeline) PIPELINE="${2:-plain}"; shift 2 ;;
    --task-id) TASK_ID="${2:-}"; shift 2 ;;
    --relation) RELATION="${2:-}"; shift 2 ;;
    --source) SOURCE="${2:-}"; shift 2 ;;
    --author) AUTHOR="${2:-}"; shift 2 ;;
    --answers) ANSWERS="${2:-}"; shift 2 ;;
    *) break ;;
  esac
done
case "$MODE" in conversation|continue) ;; *) echo "❌ невідомий --mode: $MODE" >&2; exit 1 ;; esac
[ "$MESSAGE_ID" = "-" ] && MESSAGE_ID=""
[ "$PIPELINE" = "-" ] && PIPELINE="plain"
case "$PIPELINE" in *[!a-z0-9-]*|"") PIPELINE="plain" ;; esac
# A pipeline somebody built is checked HERE, while the app is still waiting for an answer: a name
# that does not exist, or a description that would not run, is refused with the reason instead of
# being accepted and quietly prepared some other way.
case "$PIPELINE" in
  plain|adaptive-peer|dispatch|dispatch-legacy) ;;
  *) if ! _why="$(python3 "$BIN_DIR/pipeline-tool.py" check "$PIPELINE" 2>&1 >/dev/null)"; then
       echo "❌ ${_why:-Пайплайн «${PIPELINE}» не можна запустити}" >&2
       exit 1
     fi ;;
esac

PROJ="$(canon_path "${1:?usage: worker-send.sh [--mode conversation|continue] <dir> <session-id|-> <branch|-> <run-id|-> <message>}")"; shift
SID="${1:-"-"}"; shift || true
BR="${1:-"-"}"; shift || true
RID="${1:-"-"}"; shift || true
MSG="$*"
[ -d "$PROJ" ] || { echo "❌ Нема такої теки: $PROJ" >&2; exit 1; }
[ -n "$MSG" ] || { echo "❌ Порожнє повідомлення" >&2; exit 1; }
[ "$SID" = "-" ] && SID=""
[ "$BR" = "-" ] && BR=""
[ "$RID" = "-" ] && RID=""

slug="$(slug_for "$PROJ")"; session="$(session_name "$slug")"
export INJECT_LOG="$SUP_STATE/supervisor.log"

# ------------------------------------------------------------------ a bridge's message on a server
#
# Each message to a task is an attempt of its own in a fresh session (`dispatch.sh --continue`),
# briefed from the task's record: the goal and criteria it started with, where its branches stand,
# and what is new. Nothing is typed into a live session and nothing waits in a queue here — while an
# attempt runs the answer is `busy` and the bridge keeps the message until the attempt is settled.
#   TIER=dispatched / exit 0   accepted, a new attempt started
#   TIER=duplicate  / exit 0   this message id was already taken (the earlier receipt is printed)
#   TIER=conflict   / exit 4   same message id with a different text, or an answer to no open question
#   TIER=busy       / exit 6   an attempt of this task is running
#   exit 2                     unknown task for `continue`, existing task for `new`, bad arguments
if [ "${SUPERVISOR_PROFILE:-}" = server ] || [ -n "$TASK_ID" ]; then
  [ -n "$TASK_ID" ] || { echo "❌ на сервері потрібен --task-id" >&2; exit 2; }
  valid_task_id "$TASK_ID" || { echo "❌ --task-id: «${TASK_ID}»" >&2; exit 2; }
  case "$RELATION" in continue|new) ;; *) echo "❌ --relation continue|new обовʼязковий" >&2; exit 2 ;; esac
  [ -z "$SOURCE" ] || valid_source "$SOURCE" || { echo "❌ --source: «${SOURCE}»" >&2; exit 2; }
  [ -z "$AUTHOR" ] || valid_author "$AUTHOR" || { echo "❌ --author: «${AUTHOR}»" >&2; exit 2; }
  _fwd=(--task-id "$TASK_ID")
  [ -n "$MESSAGE_ID" ] && _fwd+=(--message-id "$MESSAGE_ID")
  [ -n "$SOURCE" ] && _fwd+=(--source "$SOURCE")
  [ -n "$AUTHOR" ] && _fwd+=(--author "$AUTHOR")
  if [ "$RELATION" = new ]; then
    task_exists "$TASK_ID" && { echo "❌ задача $TASK_ID уже є — для неї --relation continue" >&2; exit 2; }
    exec "$BIN_DIR/dispatch.sh" "${_fwd[@]}" ${BR:+--branch "$BR"} "$PROJ" "$MSG"
  fi
  task_exists "$TASK_ID" || { echo "❌ задачі $TASK_ID немає — нічого продовжувати (--relation new?)" >&2; exit 2; }
  # A repeat is answered before anything else, busy or not: it was already accepted.
  _mc="$(task_message_check "$TASK_ID" "$MESSAGE_ID" "$MSG")"
  case "${_mc%%$'\n'*}" in
    duplicate) echo "TIER=duplicate"; printf '%s' "$_mc" | tail -n +2 | jq -c --arg t "$TASK_ID" '. + {task_id:$t}'; exit 0 ;;
    conflict)  echo "TIER=conflict"; echo "❌ повідомлення $MESSAGE_ID для $TASK_ID уже прийняте з іншим текстом" >&2; exit 4 ;;
  esac
  task_busy "$TASK_ID" && { echo "TIER=busy"; echo "задача $TASK_ID зараз у роботі — надішли після вердикту" >&2; exit 6; }
  if [ -n "$ANSWERS" ]; then
    [ "$(task_get "$TASK_ID" '.question.id')" = "$ANSWERS" ] \
      || { echo "TIER=conflict"; echo "❌ питання $ANSWERS для $TASK_ID не відкрите" >&2; exit 4; }
  fi
  _branch="$(task_get "$TASK_ID" .branch)"
  _base="$(task_get "$TASK_ID" .base_sha)"
  _brief="$(task_brief "$TASK_ID" "$MSG" "${SOURCE:-other}" "${AUTHOR:-unknown}" "$ANSWERS")"
  _rs=(); [ -s "$(task_dir "$TASK_ID")/material/runspec.json" ] && _rs=(--runspec "$(task_dir "$TASK_ID")/material/runspec.json")
  # The message id is recorded against the message as it came, not against the brief built around it.
  _out="$(SUPERVISOR_TASK_RAW_MESSAGE="$MSG" "$BIN_DIR/dispatch.sh" --continue "${_fwd[@]}" ${_branch:+--branch "$_branch"} \
           ${_base:+--review-base "$_base"} --dirty fail ${_rs[@]+"${_rs[@]}"} "$PROJ" "$_brief" 2>&1)"; _rc=$?
  printf '%s\n' "$_out"
  exit "$_rc"
fi

# Whose choices this send runs on.
#
# When the app is the caller it IS the authority: what the composer is showing right now is what a
# preflight, a consultation and the review gate must use — so its values are kept as they are and
# written down LATER, once this run is confirmed to belong to this conversation. Writing them here
# would let a chat whose message is about to be refused as somebody else's run change that run's
# model and depth on its way out.
#
# Anyone else — a script, a hook, a relay — is only reading what the run was configured with.
[ "${SUPERVISOR_RUN_ENV_FROM_APP:-0}" = 1 ] || run_env_load "$SUP_INSTANCES/$slug"

# Called only where ownership has just been established.
adopt_run_env() {   # $1 = instance dir
  [ "${SUPERVISOR_RUN_ENV_FROM_APP:-0}" = 1 ] && [ -d "${1:-}" ] && run_env_save "$1"
  return 0
}

# The engine's own switches outrank the caller's wish. Preflight turned off, or a run deliberately
# put back on the legacy flow, means nothing gets prepared — and the log says which switch decided.
if [ "$PIPELINE" != plain ]; then
  if [ "${SUPERVISOR_PREFLIGHT_ENABLE:-1}" != 1 ]; then
    echo "$(date '+%F %T') [worker-send] SUPERVISOR_PREFLIGHT_ENABLE=0 — $PIPELINE downgraded to plain" >> "${SUPERVISOR_STATE_DIR:-$HOME/.claude/supervisor}/supervisor.log"
    PIPELINE=plain
  # The collaboration switch speaks for the built-in flow only; a pipeline someone chose by name is
  # that choice, and a stale switch must not quietly turn it into plain.
  elif [ "${SUPERVISOR_COLLABORATION_MODE:-adaptive_peer}" != adaptive_peer ] \
       && { [ "$PIPELINE" = adaptive-peer ] || [ "$PIPELINE" = dispatch ]; }; then
    echo "$(date '+%F %T') [worker-send] collaboration mode is ${SUPERVISOR_COLLABORATION_MODE:-} — $PIPELINE downgraded to plain" >> "${SUPERVISOR_STATE_DIR:-$HOME/.claude/supervisor}/supervisor.log"
    PIPELINE=plain
  fi
fi

# A message that has to be prepared is never typed at the worker here. It is put in the instance's
# own queue and a pump takes it from there: preparation runs for minutes, and this call has to come
# back in seconds or the app's own timeout kills the shell that started it.
prepared_send() {   # $1 = instance dir ; echoes the tier and exits
  local idir="$1" f
  f="$(pending_enqueue "$idir" "$MSG" "$MESSAGE_ID" "$PIPELINE" "$MODE")" || {
    echo "$(date '+%F %T') [worker-send] could not queue a prepared message — falling back to plain" >> "$SUP_STATE/supervisor.log"
    return 1
  }
  nohup "${SUPERVISOR_PUMP_CMD:-$BIN_DIR/message-pump.sh}" "$slug" >/dev/null 2>&1 &
  disown 2>/dev/null || true
  echo "$(date '+%F %T') [worker-send] queued $(basename "$f") for the $PIPELINE pipeline" >> "$SUP_STATE/supervisor.log"
  echo "TIER=preparing"
  echo "↳ Готую незалежні позиції Claude і Codex — щойно вони готові, задача піде в роботу"
  exit 5
}

if tmux has-session -t "$session" 2>/dev/null; then
  inst_rid="$(tr -d '[:space:]' < "$SUP_INSTANCES/$slug/run-id" 2>/dev/null)"
  want_rid="$(printf '%s' "$RID" | tr -d '[:space:]')"
  inst_branch="$(tr -d '[:space:]' < "$SUP_INSTANCES/$slug/branch" 2>/dev/null)"
  want_branch="$(printf '%s' "$BR" | tr -d '[:space:]')"
  ok=0; why=""
  if [ -n "$inst_rid" ]; then
    if [ -n "$want_rid" ] && [ "$want_rid" = "$inst_rid" ]; then ok=1; else why="run-id '$inst_rid' ≠ '$want_rid'"; fi
  elif [ -n "$want_branch" ] && [ -n "$inst_branch" ] && [ "$want_branch" = "$inst_branch" ]; then
    ok=1   # instance has no run-id (legacy) — branch is the best signal available
  else
    why="нема run-id інстанса й гілка не збігається"
  fi
  if [ "$ok" != 1 ]; then
    echo "TIER=conflict"
    echo "жива сесія $session — інший/непідтверджений ран ($why); не інжектю"
    exit 4
  fi
  # Past the run-id and branch check: this session is ours, so the composer's choices may be
  # written down for it.
  adopt_run_env "$SUP_INSTANCES/$slug"
  if [ "$MODE" = "conversation" ] && [ "$PIPELINE" != plain ]; then
    prepared_send "$SUP_INSTANCES/$slug" || true
  fi
  if [ "$MODE" = "conversation" ] && _turn_running "$session"; then
    park_undelivered "$SUP_INSTANCES/$slug" "$MSG" "$MESSAGE_ID"
    echo "TIER=queued"
    echo "↳ Сесія працює — повідомлення у черзі й буде доставлене наступним"
    exit 2
  fi
  if [ "$MODE" = "continue" ]; then
    _directive="$(open_revision "$SUP_INSTANCES/$slug" "$MSG")"
    [ -n "$_directive" ] && MSG="$MSG

$_directive"
  fi
  # One thing typed at a time. The watchdog can decide to resume in the same second the app sends,
  # and two processes at one composer is how a message ends up half-pasted inside another.
  if ! delivery_claim "$SUP_INSTANCES/$slug" "worker-send"; then
    park_undelivered "$SUP_INSTANCES/$slug" "$MSG" "$MESSAGE_ID"
    echo "TIER=queued"
    echo "↳ Композер зараз зайнятий іншою передачею — повідомлення у черзі, доставлю наступним"
    exit 2
  fi
  trap 'delivery_release "$SUP_INSTANCES/$slug"' EXIT
  inject_task "$session" "$MSG"; rc=$?
  case "$rc" in
    0) # A turn is confirmed running. What that MEANS depends on the intent: more work
       if [ "$MODE" = "continue" ]; then
         rm -f "$SUP_INSTANCES/$slug/done" "$SUP_INSTANCES/$slug/awaiting-codex" "$SUP_INSTANCES/$slug/paused-for-limit.json" \
               "$SUP_INSTANCES/$slug/outcome.json" "$SUP_INSTANCES/$slug/stalled.json" 2>/dev/null || true
         echo "▶ Передано у живу сесію $session (нова ревізія)"
       else
         echo "▶ Передано у живу сесію $session"
       fi
       [ -n "$MESSAGE_ID" ] && reset_review_budget "$SUP_INSTANCES/$slug"
       rm -f "$SUP_INSTANCES/$slug/resume-pending" 2>/dev/null || true
       echo "TIER=live"
       exit 0 ;;
    2) # Typed but nothing started — almost always a usage limit. inject_task has already
       park_undelivered "$SUP_INSTANCES/$slug" "$MSG" "$MESSAGE_ID"
       echo "TIER=queued"
       echo "⚠ Хід не підтвердився (ліміт/зайнято) — повідомлення у черзі, доставлю коли сесія оживе"; exit 2 ;;
    *) # Anything else: the keystrokes did not land. Park it exactly as we do for a limit —
       park_undelivered "$SUP_INSTANCES/$slug" "$MSG" "$MESSAGE_ID"
       echo "TIER=queued"
       echo "⚠ Сесія не прийняла ввід (rc=$rc) — повідомлення у черзі, доставлю коли вона звільниться"
       exit 2 ;;
  esac
fi

# A run that still owes work — a review, a resume, a window it is parked on, messages it accepted —
# is brought back as it was rather than replaced. `resume` below deletes the instance and starts a
# new run, and the review it owed went with it, a signed "wait for Codex" too: a chat parked on
# Codex lost its review the moment someone wrote to it. Only for this conversation's own run.
if [ -n "$SID" ] && [ -z "${SUPERVISOR_REVIVED:-}" ] && instance_owes_work "$SUP_INSTANCES/$slug" \
   && [ -s "$SUP_INSTANCES/$slug/relaunch-template" ] \
   && [ "$(tr -d '[:space:]' < "$SUP_INSTANCES/$slug/claude-session-id" 2>/dev/null)" = "$(printf '%s' "$SID" | tr -d '[:space:]')" ] \
   && { [ -z "$RID" ] || [ "$(tr -d '[:space:]' < "$SUP_INSTANCES/$slug/run-id" 2>/dev/null)" = "$(printf '%s' "$RID" | tr -d '[:space:]')" ]; }; then
  "${SUPERVISOR_NIGHT_SHIFT_CMD:-$BIN_DIR/night-shift.sh}" revive "$PROJ" >>"$SUP_STATE/supervisor.log" 2>&1; _rv=$?
  if [ "$_rv" = 0 ] && tmux has-session -t "$session" 2>/dev/null; then
    echo "$(date '+%F %T') [worker-send] $slug: the run still owed work — brought back in place, delivering to it" >> "$SUP_STATE/supervisor.log"
    SUPERVISOR_REVIVED=1 exec bash "$SELF" "${WS_ARGS[@]}"
  fi
  case "$_rv" in
    3|4) # Nothing to bring back, or stopped / replaced: the old way below is what is left.
      echo "$(date '+%F %T') [worker-send] $slug: not revived (rc=$_rv) — falling back to resume" >> "$SUP_STATE/supervisor.log" ;;
    *) # Tried and failed, or its Claude still runs: the message waits with the work, which is not
       # thrown away for a fresh start.
      park_undelivered "$SUP_INSTANCES/$slug" "$MSG" "$MESSAGE_ID"
      echo "$(date '+%F %T') [worker-send] $slug: the run owes work and could not be brought back (rc=$_rv) — message parked, nothing deleted" >> "$SUP_STATE/supervisor.log"
      echo "TIER=queued"
      echo "⚠ Сесію поки не вдалося підняти — повідомлення у черзі, незавершену роботу збережено"
      exit 2 ;;
  esac
fi

if [ -n "$SID" ]; then
  # The launcher is a seam for the same reason the watchdog and the pump are: reviving a session
  # means starting a real Claude, and the suite has to be able to prove what happens AFTER it.
  # Into a file and not straight into the log: the marker lines it prints for the app (a sign-in,
  # a conversation Claude no longer keeps) went only to the log, and the app, told nothing but
  # TIER=none, took a signed-out Claude for a broken resume (1.16.1, 23.10).
  _rout="$(mktemp "${TMPDIR:-/tmp}/worker-send-resume.XXXXXX")"
  "${SUPERVISOR_NIGHT_SHIFT_CMD:-$BIN_DIR/night-shift.sh}" resume "$PROJ" "$SID" "${BR:-"-"}" --no-attach >"$_rout" 2>&1
  _rs=$?
  cat "$_rout" >> "$SUP_STATE/supervisor.log" 2>/dev/null
  grep -E '^(handshake-blocked|resume-refused)=' "$_rout" 2>/dev/null
  rm -f "$_rout"
  if [ "$_rs" = 4 ]; then
    # The conversation is alive in another run. Starting it here as well is how one message once
    # went into his folder while the run it belonged to was working in its copy.
    echo "TIER=conflict"
    echo "ця розмова вже працює в іншому прогоні — другу копію не запускаю"
    exit 4
  fi
  if [ "$_rs" = 0 ] && tmux has-session -t "$session" 2>/dev/null; then
    adopt_run_env "$SUP_INSTANCES/$slug"
    if [ "$MODE" = "conversation" ] && [ "$PIPELINE" != plain ]; then
      # After the resume, so the envelope carries the run id the revived session actually has.
      prepared_send "$SUP_INSTANCES/$slug" || true
    fi
    if [ "$MODE" = "continue" ]; then
    _directive="$(open_revision "$SUP_INSTANCES/$slug" "$MSG")"
    [ -n "$_directive" ] && MSG="$MSG

$_directive"
  fi
  inject_task "$session" "$MSG"; rc=$?
    case "$rc" in
      0) [ -n "$MESSAGE_ID" ] && reset_review_budget "$SUP_INSTANCES/$slug"
         rm -f "$SUP_INSTANCES/$slug/resume-pending" 2>/dev/null || true
         echo "TIER=resumed"; echo "▶ Відновлено сесію та передано"; exit 0 ;;
      2) park_undelivered "$SUP_INSTANCES/$slug" "$MSG" "$MESSAGE_ID"
         echo "TIER=queued"; echo "⚠ Відновлено, але хід не підтвердився — повідомлення у черзі"; exit 2 ;;
      *) park_undelivered "$SUP_INSTANCES/$slug" "$MSG" "$MESSAGE_ID"
         echo "TIER=queued"; echo "⚠ Відновлено, але сесія не прийняла ввід (rc=$rc) — повідомлення у черзі"; exit 2 ;;
    esac
  fi
  echo "$(date '+%F %T') [worker-send] resume failed for $SID (rc=$_rs) — nothing started, the caller decides what next" >> "$SUP_STATE/supervisor.log"
fi

echo "TIER=none"
echo "нема живої/відновлюваної сесії — потрібен свіжий воркер"
exit 3
