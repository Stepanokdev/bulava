#!/bin/bash
set -u
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac; done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"
. "$BIN_DIR/supervisor-lib.sh"

RUNSPEC_SRC=""
CALLER_REPORT_KEY=""
CALLER_DISPATCH_ID=""
# A bridge's own: which task this is, where its branch starts, what to do about a dirty tree, and
# who wrote the text. The first three are handed to `start`; none is required off a server.
TASK_ID=""; START_FLAGS=(); SOURCE=""; AUTHOR=""; MESSAGE_ID=""; CONTINUE_ATTEMPT=0; REVIEW_BASE=""
while :; do
  case "${1:-}" in
    --runspec)     RUNSPEC_SRC="$2"; shift 2 ;;
    --report-key)  CALLER_REPORT_KEY="$2"; shift 2 ;;
    --dispatch-id) CALLER_DISPATCH_ID="$2"; shift 2 ;;
    --task-id)     TASK_ID="${2:-}"; shift 2 ;;
    --branch)      START_FLAGS+=(--branch "${2:-}"); shift 2 ;;
    --base)        START_FLAGS+=(--base "${2:-}"); shift 2 ;;
    --dirty)       START_FLAGS+=("--dirty=${2:-}"); shift 2 ;;
    --dirty=*)     START_FLAGS+=("$1"); shift ;;
    --source)      SOURCE="${2:-}"; shift 2 ;;
    --author)      AUTHOR="${2:-}"; shift 2 ;;
    --message-id)  MESSAGE_ID="${2:-}"; shift 2 ;;
    # Internal: `worker-send` starting the next attempt of a task it found. Not for a bridge.
    --continue)    CONTINUE_ATTEMPT=1; shift ;;
    --review-base) REVIEW_BASE="${2:-}"; START_FLAGS+=("--review-base=${2:-}"); shift 2 ;;
    *) break ;;
  esac
done
# Checked before anything is started, cleared or switched: a bad identifier must cost nothing.
[ -z "$TASK_ID" ] || valid_task_id "$TASK_ID" || { echo "❌ --task-id: «${TASK_ID}» — лише літери, цифри, . _ -, до 64 символів" >&2; exit 2; }
[ -z "$SOURCE" ] || valid_source "$SOURCE" || { echo "❌ --source: «${SOURCE}» — youtrack, mr, ci, gitlab, tracker або other" >&2; exit 2; }
[ -z "$AUTHOR" ] || valid_author "$AUTHOR" || { echo "❌ --author: «${AUTHOR}» — схоже не на логін" >&2; exit 2; }
[ -z "$MESSAGE_ID" ] || printf '%s' "$MESSAGE_ID" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$' \
  || { echo "❌ --message-id: «${MESSAGE_ID}» — лише літери, цифри, . _ : -" >&2; exit 2; }
[ "$CONTINUE_ATTEMPT" = 0 ] || [ -n "$TASK_ID" ] || { echo "❌ --continue без --task-id" >&2; exit 2; }

PROJ="$(canon_path "${1:?usage: dispatch.sh <dir> <task>}")"; shift
TASK="$*"
[ -d "$PROJ" ] || { echo "❌ Нема такої теки: $PROJ" >&2; exit 1; }
# On a server an empty task is a bridge's mistake, not an invitation to do whatever the repository
# suggests, and a runspec that was named but cannot be read must not quietly become a broad run.
if [ "${SUPERVISOR_PROFILE:-}" = server ]; then
  [ -n "$(printf '%s' "$TASK" | tr -d '[:space:]')" ] || { echo "❌ порожня задача — на сервері її не вигадую" >&2; exit 2; }
  if [ -n "$RUNSPEC_SRC" ] && ! { [ -s "$RUNSPEC_SRC" ] && jq -e . "$RUNSPEC_SRC" >/dev/null 2>&1; }; then
    echo "❌ --runspec: «${RUNSPEC_SRC}» не читається як JSON — без нього не запускаю" >&2; exit 2
  fi
fi
[ -n "$TASK" ] || TASK="Виконай задачу цього проєкту повністю за SPEC.md (а якщо його нема — за вмістом репозиторію). Доведи до кінця, без заглушок і 'на потім'."
# What dedup and the record are keyed on: the message as the bridge sent it. A follow-up arrives
# wrapped in a brief, and the same comment must hash the same however its brief came out.
RAW_TASK="${SUPERVISOR_TASK_RAW_MESSAGE:-$TASK}"
unset SUPERVISOR_TASK_RAW_MESSAGE
[ -n "$SOURCE" ] && [ "$CONTINUE_ATTEMPT" = 0 ] && TASK="$(untrusted_frame "$SOURCE" "${AUTHOR:-unknown}" "$TASK")"

slug="$(slug_for "$PROJ")"; session="$(session_name "$slug")"; idir="$(instance_dir "$slug")"
export INJECT_LOG="$SUP_STATE/supervisor.log"

# A task the bridge named. Everything here is decided before a session is touched, so a refusal
# costs nothing and a repeat costs nothing either.
#   exit 0 + TIER=duplicate   this message was already taken for this task: the earlier receipt
#   exit 4 + TIER=conflict    same message id, different text
#   exit 6 + TIER=busy        an attempt of this task — or another task in this folder — is running
#   exit 2                    a new task under an existing id, or a follow-up to one that does not exist
if [ -n "$TASK_ID" ]; then
  # Admission is one step: from "is this task free" to "the new attempt is on the record" nobody else
  # may decide anything about this folder (`task_lifecycle_lock`). Released below, once the attempt
  # is recorded, and on any exit before that.
  task_lifecycle_lock "$PROJ" || { echo "TIER=busy"; echo "тека $PROJ зайнята іншим стартом" >&2; exit 6; }
  trap 'task_lifecycle_unlock "$PROJ"' EXIT
  if task_exists "$TASK_ID"; then
    _mc="$(task_message_check "$TASK_ID" "$MESSAGE_ID" "$RAW_TASK")"
    case "${_mc%%$'\n'*}" in
      duplicate) echo "TIER=duplicate"; printf '%s\n' "$(printf '%s' "$_mc" | tail -n +2 | jq -c --arg t "$TASK_ID" '. + {task_id:$t}')"; exit 0 ;;
      conflict)  echo "TIER=conflict"; echo "❌ повідомлення $MESSAGE_ID для $TASK_ID уже прийняте з іншим текстом" >&2; exit 4 ;;
    esac
    if [ "$CONTINUE_ATTEMPT" = 0 ] && [ "${SUPERVISOR_PROFILE:-}" = server ]; then
      echo "❌ задача $TASK_ID уже є — продовження йде через worker-send --relation continue" >&2; exit 2
    fi
    task_busy "$TASK_ID" && { echo "TIER=busy"; echo "задача $TASK_ID зараз у роботі" >&2; exit 6; }
  elif [ "$CONTINUE_ATTEMPT" = 1 ]; then
    echo "❌ задачі $TASK_ID немає — нічого продовжувати" >&2; exit 2
  fi
  # One folder, one attempt at a time: another task's work here is not ours to stop.
  _other="$(cat "$idir/task-id" 2>/dev/null || true)"
  if [ -n "$_other" ] && [ "$_other" != "$TASK_ID" ] && task_busy "$_other"; then
    echo "TIER=busy"; echo "у цій теці зараз працює задача $_other" >&2; exit 6
  fi
  # On a server every attempt starts from a fresh session: what it needs is in the task's record,
  # and a session left over from the previous attempt is only somewhere for it to come apart.
  if [ "${SUPERVISOR_PROFILE:-}" = server ] && tmux has-session -t "$session" 2>/dev/null; then
    "$BIN_DIR/night-shift.sh" stop "$PROJ" >> "$SUP_STATE/supervisor.log" 2>&1 || true
  fi
fi

if ! supervised_session_live "$slug"; then
  if tmux has-session -t "$session" 2>/dev/null; then
    echo "$(date '+%F %T') [dispatch] session $session is up but not a confirmed supervised run — full restart" \
      >> "$SUP_STATE/supervisor.log"
  fi
  start_out="$(SUPERVISOR_TASK_ID="$TASK_ID" "$BIN_DIR/night-shift.sh" start "$PROJ" --no-attach ${START_FLAGS[@]+"${START_FLAGS[@]}"} 2>&1)"; start_rc=$?
  printf '%s\n' "$start_out" >> "$SUP_STATE/supervisor.log"
  if [ "$start_rc" != 0 ]; then
    reason="$(printf '%s\n' "$start_out" | grep -E '^(❌|⚠️|fatal:|error:)' | tail -2 | tr '\n' ' ')"
    [ -n "$reason" ] || reason="$(printf '%s\n' "$start_out" | grep -v '^$' | tail -1)"
    echo "❌ ${reason:-night-shift start не вдалося} ($PROJ)" >&2
    # 76 is not a failure, it is a question — this folder has no git and the engine will not create
    # one without being told to. Folded into 1 it reached the app as text with a terminal command in
    # it; kept, the app can answer it with a button, exactly as the chat does.
    [ "$start_rc" = 76 ] && exit 76
    # 77 is the same kind of answer: the folder holds uncommitted work and the engine will not
    # commit it, stash it or start on top of it until the director says which.
    [ "$start_rc" = 77 ] && exit 77
    # 78: the project's MCP servers, which Claude would stop to ask about where nobody can answer.
    [ "$start_rc" = 78 ] && exit 78
    # 79: a first checkpoint that would not fit, and the files that make it heavy are named — the
    # director can leave them out of checkpoints instead of reading about megabytes.
    [ "$start_rc" = 79 ] && exit 79
    exit 1
  fi
fi

mkdir -p "$idir" 2>/dev/null || true
wd_pid="$(cat "$idir/watchdog.pid" 2>/dev/null || echo "")"
if ! { [ -n "$wd_pid" ] && kill -0 "$wd_pid" 2>/dev/null; }; then
  WD_CMD="${SUPERVISOR_WATCHDOG_CMD:-$BIN_DIR/watchdog.sh}"
  nohup "$WD_CMD" "$slug" >/dev/null 2>&1 &
  echo $! > "$idir/watchdog.pid"
  sleep 1
  if kill -0 "$(cat "$idir/watchdog.pid" 2>/dev/null)" 2>/dev/null; then
    echo "$(date '+%F %T') [dispatch] watchdog (re)started for reused session $session" >> "$SUP_STATE/supervisor.log"
  else
    echo "❌ watchdog не піднявся для сесії $session" >&2; exit 1
  fi
fi

mkdir -p "$idir" 2>/dev/null || true
rm -f "$idir/done" "$idir/outcome.json" "$idir/stalled.json" 2>/dev/null || true
DISPATCH_ID="${CALLER_DISPATCH_ID:-$(uuidgen 2>/dev/null || printf '%s-%s' "$(date +%s)" "$$")}"
if [ -n "$CALLER_REPORT_KEY" ]; then
  REPORT_KEY="$CALLER_REPORT_KEY"
else
  REPORT_KEY="$(printf '%s' "$DISPATCH_ID" | tr 'A-Z' 'a-z' | tr -cd 'a-f0-9' | cut -c1-8)"
fi
REPORT_DIR="$SUP_STATE/reports/$REPORT_KEY"
mkdir -p "$REPORT_DIR" 2>/dev/null || true
mkdir -p "$idir/dispatches" 2>/dev/null || true
if [ -n "$TASK_ID" ]; then
  printf '%s\n' "$TASK_ID" > "$idir/task-id"
  _branch_now="$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || true)"
  task_exists "$TASK_ID" || task_create "$TASK_ID" "$PROJ" "$SOURCE" "$AUTHOR" "$TASK" "$_branch_now" \
      "$(printf '%s\n' "${START_FLAGS[@]+"${START_FLAGS[@]}"}" | awk 'p{print; exit} $0=="--base"{p=1}')" \
    || { echo "❌ не зміг записати задачу $TASK_ID" >&2; exit 1; }
else
  rm -f "$idir/task-id" 2>/dev/null
fi
jq -nc --arg id "$DISPATCH_ID" --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg task "$TASK" \
   --arg rk "$REPORT_KEY" --arg tid "$TASK_ID" --arg src "$SOURCE" --arg au "$AUTHOR" \
   '{id:$id, at:$at, task:$task, report_key:$rk}
    + (if $tid == "" then {} else {task_id:$tid} end)
    + (if $src == "" then {} else {source:$src} end)
    + (if $au  == "" then {} else {author:$au} end)' > "$idir/dispatch.json.tmp" 2>/dev/null \
  && cp -f "$idir/dispatch.json.tmp" "$idir/dispatches/$DISPATCH_ID.json" 2>/dev/null \
  && mv -f "$idir/dispatch.json.tmp" "$idir/dispatch.json" \
  || rm -f "$idir/dispatch.json.tmp" 2>/dev/null || true

# A dispatch carries the task and nothing the product remembers about itself. Anything left by
# an older version of the engine is removed here rather than ignored: a file that still exists is
# a file something downstream can start reading again.
rm -f "$idir/product-memory.md" 2>/dev/null || true

if [ -z "$CALLER_REPORT_KEY" ]; then
  DIRECTIVE="$(report_directive "$REPORT_DIR")"
  [ -n "$DIRECTIVE" ] && TASK="$TASK

$DIRECTIVE"
fi
if [ -n "$RUNSPEC_SRC" ] && [ -s "$RUNSPEC_SRC" ] && jq -e . "$RUNSPEC_SRC" >/dev/null 2>&1; then
  cp "$RUNSPEC_SRC" "$idir/runspec.json.tmp" && mv -f "$idir/runspec.json.tmp" "$idir/runspec.json"
  echo "$(date '+%F %T') [dispatch] runspec installed (mode=$(runspec_mode "$idir")) → $session" >> "$SUP_STATE/supervisor.log"
else
  rm -f "$idir/runspec.json" 2>/dev/null || true   # stale spec from a prior scoped dispatch must not leak
  [ -n "$RUNSPEC_SRC" ] && echo "$(date '+%F %T') [dispatch] runspec source missing/invalid ($RUNSPEC_SRC) — running broad" >> "$SUP_STATE/supervisor.log"
fi
if [ -n "$TASK_ID" ]; then
  # A follow-up is reviewed against the task as it was agreed: its runspec, plan and research go back
  # in place before anything reads them.
  [ "$CONTINUE_ATTEMPT" = 1 ] && task_material_restore "$TASK_ID" "$idir"
  task_attempt_begin "$TASK_ID" "$idir" "$DISPATCH_ID" "$([ "$CONTINUE_ATTEMPT" = 1 ] && echo continue || echo initial)" \
    || { echo "❌ не зміг записати спробу задачі $TASK_ID" >&2; exit 1; }
  task_message_record "$TASK_ID" "$MESSAGE_ID" "$RAW_TASK" "$DISPATCH_ID" || true
  [ -s "$idir/runspec.json" ] && task_material_save "$TASK_ID" "$idir"
fi
[ -n "$TASK_ID" ] && { task_lifecycle_unlock "$PROJ"; trap - EXIT; }
ln -sf "$BIN_DIR/report-finding.sh" "$idir/report-finding" 2>/dev/null \
  || cp -f "$BIN_DIR/report-finding.sh" "$idir/report-finding" 2>/dev/null || true
ln -sf "$BIN_DIR/worker-outcome.sh" "$idir/report-outcome" 2>/dev/null \
  || cp -f "$BIN_DIR/worker-outcome.sh" "$idir/report-outcome" 2>/dev/null || true
ln -sf "$BIN_DIR/add-check.sh" "$idir/add-check" 2>/dev/null \
  || cp -f "$BIN_DIR/add-check.sh" "$idir/add-check" 2>/dev/null || true
ln -sf "$BIN_DIR/consult-codex.sh" "$idir/consult-codex" 2>/dev/null \
  || cp -f "$BIN_DIR/consult-codex.sh" "$idir/consult-codex" 2>/dev/null || true
for _h in web-shot:web-shot.py web-video:web-video.py artifact:artifact.sh; do
  _name="${_h%%:*}"; _src="${_h##*:}"
  ln -sf "$BIN_DIR/$_src" "$idir/$_name" 2>/dev/null \
    || cp -f "$BIN_DIR/$_src" "$idir/$_name" 2>/dev/null || true
done
: > "$idir/started-at" 2>/dev/null || true
TASKFILE="$idir/.dispatch-inject-$DISPATCH_ID.txt"
printf '%s\n' "$TASK" > "$TASKFILE"
rm -f "$idir/inject-failed" 2>/dev/null || true
[ "$CONTINUE_ATTEMPT" = 1 ] && export SUPERVISOR_DISPATCH_PIPELINE=plain
nohup "$BIN_DIR/prepare-and-inject.sh" "$BIN_DIR" "$PROJ" "$session" "$SUP_STATE" \
  "$TASKFILE" "$idir" "$DISPATCH_ID" >>"$SUP_STATE/supervisor.log" 2>&1 &
disown 2>/dev/null || true

echo "▶ Запущено сесію та поставлено задачу: $(basename "$PROJ")  (сесія $session)"
# What a bridge keeps: one line it can parse, naming exactly what was accepted.
[ -n "$TASK_ID" ] && { echo "TIER=dispatched"; jq -nc --arg t "$TASK_ID" --arg d "$DISPATCH_ID" --arg m "$MESSAGE_ID" \
  --argjson n "$(task_get "$TASK_ID" '.attempts | length' || echo 0)" '{task_id:$t, dispatch_id:$d, attempt:$n} + (if $m == "" then {} else {message_id:$m} end)'; }
exit 0
