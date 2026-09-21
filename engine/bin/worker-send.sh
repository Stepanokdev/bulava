#!/bin/bash
set -u
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac; done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"
. "$BIN_DIR/supervisor-lib.sh"

MODE="conversation"
MESSAGE_ID=""
# Which pipeline this message goes through. `plain` is what the engine has always done: compose the
# standing sections and type it in. It stays the default deliberately — this script also carries
# the foreman's relays and the report runs, and none of those should start paying for two research
# calls because a chat setting changed.
PIPELINE="plain"
while [ $# -gt 0 ]; do
  case "${1:-}" in
    --mode) MODE="${2:-conversation}"; shift 2 ;;
    --message-id) MESSAGE_ID="${2:-}"; shift 2 ;;
    --pipeline) PIPELINE="${2:-plain}"; shift 2 ;;
    *) break ;;
  esac
done
case "$MODE" in conversation|continue) ;; *) echo "❌ невідомий --mode: $MODE" >&2; exit 1 ;; esac
[ "$MESSAGE_ID" = "-" ] && MESSAGE_ID=""
[ "$PIPELINE" = "-" ] && PIPELINE="plain"
case "$PIPELINE" in *[!a-z0-9-]*|"") PIPELINE="plain" ;; esac

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
  elif [ "${SUPERVISOR_COLLABORATION_MODE:-adaptive_peer}" != adaptive_peer ]; then
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

if [ -n "$SID" ]; then
  # The launcher is a seam for the same reason the watchdog and the pump are: reviving a session
  # means starting a real Claude, and the suite has to be able to prove what happens AFTER it.
  if "${SUPERVISOR_NIGHT_SHIFT_CMD:-$BIN_DIR/night-shift.sh}" resume "$PROJ" "$SID" "${BR:-"-"}" --no-attach >>"$SUP_STATE/supervisor.log" 2>&1 \
     && tmux has-session -t "$session" 2>/dev/null; then
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
  echo "$(date '+%F %T') [worker-send] resume unavailable/failed for $SID → fresh fallback" >> "$SUP_STATE/supervisor.log"
fi

echo "TIER=none"
echo "нема живої/відновлюваної сесії — потрібен свіжий воркер"
exit 3
