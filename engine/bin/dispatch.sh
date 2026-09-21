#!/bin/bash
set -u
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac; done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"
. "$BIN_DIR/supervisor-lib.sh"

RUNSPEC_SRC=""
CALLER_REPORT_KEY=""
CALLER_DISPATCH_ID=""
while :; do
  case "${1:-}" in
    --runspec)     RUNSPEC_SRC="$2"; shift 2 ;;
    --report-key)  CALLER_REPORT_KEY="$2"; shift 2 ;;
    --dispatch-id) CALLER_DISPATCH_ID="$2"; shift 2 ;;
    *) break ;;
  esac
done

PROJ="$(canon_path "${1:?usage: dispatch.sh <dir> <task>}")"; shift
TASK="$*"
[ -d "$PROJ" ] || { echo "❌ Нема такої теки: $PROJ" >&2; exit 1; }
[ -n "$TASK" ] || TASK="Виконай задачу цього проєкту повністю за SPEC.md (а якщо його нема — за вмістом репозиторію). Доведи до кінця, без заглушок і 'на потім'."

slug="$(slug_for "$PROJ")"; session="$(session_name "$slug")"; idir="$(instance_dir "$slug")"
export INJECT_LOG="$SUP_STATE/supervisor.log"

if ! supervised_session_live "$slug"; then
  if tmux has-session -t "$session" 2>/dev/null; then
    echo "$(date '+%F %T') [dispatch] session $session is up but not a confirmed supervised run — full restart" \
      >> "$SUP_STATE/supervisor.log"
  fi
  start_out="$("$BIN_DIR/night-shift.sh" start "$PROJ" --no-attach 2>&1)"; start_rc=$?
  printf '%s\n' "$start_out" >> "$SUP_STATE/supervisor.log"
  if [ "$start_rc" != 0 ]; then
    reason="$(printf '%s\n' "$start_out" | grep -E '^(❌|⚠️|fatal:|error:)' | tail -2 | tr '\n' ' ')"
    [ -n "$reason" ] || reason="$(printf '%s\n' "$start_out" | grep -v '^$' | tail -1)"
    echo "❌ ${reason:-night-shift start не вдалося} ($PROJ)" >&2; exit 1
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
jq -nc --arg id "$DISPATCH_ID" --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg task "$TASK" \
   --arg rk "$REPORT_KEY" \
   '{id:$id, at:$at, task:$task, report_key:$rk}' > "$idir/dispatch.json.tmp" 2>/dev/null \
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
nohup "$BIN_DIR/prepare-and-inject.sh" "$BIN_DIR" "$PROJ" "$session" "$SUP_STATE" \
  "$TASKFILE" "$idir" "$DISPATCH_ID" >>"$SUP_STATE/supervisor.log" 2>&1 &
disown 2>/dev/null || true

echo "▶ Запущено сесію та поставлено задачу: $(basename "$PROJ")  (сесія $session)"
exit 0
