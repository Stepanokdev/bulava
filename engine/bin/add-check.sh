#!/bin/bash
# A check the worker registers: a command the engine runs itself, whose exit code is the evidence.
#
#   add-check [--timeout SECONDS] "<criterion>" -- <command> [args...]
#                         register (the same criterion again replaces it; so does the same command,
#                         in the same folder, under another name)
#   add-check --list      what is registered for this task, and what an earlier task left aside
#   add-check --remove "<criterion>"
#                         a check that turned out wrong or no longer applies
#   add-check --restore "<criterion>" | --restore-all
#                         bring back checks the previous task registered — a new task starts with
#                         none, and the brief names the ones that were set aside
#
# At most ten per task. --timeout is the most this one check may take, up to
# SUPERVISOR_ADD_CHECK_TIMEOUT_MAX (two hours by default); without it the verifier's own step limit
# applies.
set -u
SELF="${BASH_SOURCE[0]}"; while [ -L "$SELF" ]; do d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac; done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"; . "$BIN_DIR/supervisor-lib.sh"

usage() { sed -n '4,17p' "$SELF" | sed 's/^# \{0,1\}//' >&2; }

ACTION=add; TIMEOUT=""; NAME=""
case "${1:-}" in
  --list) ACTION=list; shift ;;
  --remove) ACTION=remove; NAME="${2:-}"; shift 2 2>/dev/null || shift ;;
  --restore) ACTION=restore; NAME="${2:-}"; shift 2 2>/dev/null || shift ;;
  --restore-all) ACTION=restore-all; shift ;;
  -h|--help) usage; exit 0 ;;
esac
if [ "$ACTION" = add ] && [ "${1:-}" = --timeout ]; then
  TIMEOUT="${2:-}"; shift 2 2>/dev/null || shift
  case "$TIMEOUT" in ''|*[!0-9]*) echo "❌ --timeout приймає ціле число секунд" >&2; exit 2 ;; esac
  _max="${SUPERVISOR_ADD_CHECK_TIMEOUT_MAX:-7200}"; case "$_max" in ''|*[!0-9]*) _max=7200 ;; esac
  [ "$TIMEOUT" -ge 10 ] || { echo "❌ --timeout щонайменше 10 секунд" >&2; exit 2; }
  if [ "$TIMEOUT" -gt "$_max" ]; then
    echo "⚠️  --timeout $TIMEOUT більше за стелю $_max с — записую $_max" >&2; TIMEOUT="$_max"
  fi
fi
case "$ACTION" in
  remove|restore) [ -n "$NAME" ] || { usage; exit 2; } ;;
esac

# The run this process belongs to, asked of the process first. `slug_for "$PWD"` was an exact-path
# match, so registering a check from a SUBFOLDER of the project — never mind from an allowed
# neighbouring repository — pointed at an instance folder that does not exist.
scope="$(worker_scope "$PWD")"
if [ "${scope%%:*}" = instance ]; then
  IDIR="$(instance_dir "${scope#instance:}")"      # the run itself, and it outranks any override
elif [ ! -d "${IDIR:-}" ]; then
  if [ -n "${ORCHESTRATOR_RUN_ID:-}" ]; then
    echo "❌ перевірку НЕ записано — прогін $ORCHESTRATOR_RUN_ID більше не існує" >&2; exit 1
  fi
  slug="$(slug_for "$PWD")"; IDIR="$(instance_dir "$slug")"
fi
[ -d "$IDIR" ] || { echo "❌ нема теки прогону — запусти через night-shift" >&2; exit 1; }

CHECKS="$IDIR/checks.jsonl"
MAX_CHECKS=10
count() { grep -c . "$CHECKS" 2>/dev/null || echo 0; }

# Keep only the lines the jq filter selects. The file is the run's control state: written whole,
# through a temporary file, or not at all.
keep_where() {   # $1 = jq filter over one check  [jq --arg pairs…]
  local filter="$1"; shift
  [ -f "$CHECKS" ] || return 0
  jq -c "$@" "select($filter)" "$CHECKS" > "$CHECKS.tmp.$$" 2>/dev/null \
    && mv -f "$CHECKS.tmp.$$" "$CHECKS" \
    || { rm -f "$CHECKS.tmp.$$"; return 1; }
}

# The checks an earlier task registered and the engine set aside when this one began.
set_aside_file() {
  local f
  f="$(jq -r '.file // empty' "$IDIR/checks-set-aside.json" 2>/dev/null)"
  [ -n "$f" ] && [ -s "$f" ] && { printf '%s' "$f"; return 0; }
  return 1
}

# One check, written: replacing one of the same name, and one with the same command in the same
# folder under another name — four copies of one command, each under a new name, is how a task ran
# out of its ten (Tenders, 5 Nov).
write_check() {   # $1 = criterion  $2 = argv JSON  $3 = cwd  $4 = timeout (or "")
  local crit="$1" argv="$2" cwd="$3" to="$4" replaced="" line
  if [ -f "$CHECKS" ]; then
    replaced="$(jq -r --arg c "$crit" --argjson a "$argv" --arg w "$cwd" \
                 'select(.criterion == $c or (.argv == $a and (.cwd // "") == $w)) | .criterion' "$CHECKS" 2>/dev/null)"
    if [ -n "$replaced" ]; then
      keep_where '.criterion != $c and ((.argv == $a and (.cwd // "") == $w) | not)' \
        --arg c "$crit" --argjson a "$argv" --arg w "$cwd" \
        || { echo "❌ не зміг замінити попередню перевірку" >&2; return 1; }
    fi
  fi
  if [ "$(count)" -ge "$MAX_CHECKS" ]; then
    echo "❌ вже $MAX_CHECKS перевірок — більше не додаю. Прибери зайву (--remove) або об'єднай їх в одну команду." >&2
    return 2
  fi
  line="$(jq -nc --arg c "$crit" --argjson argv "$argv" --arg cwd "$cwd" --arg to "$to" \
       --arg ts "$(date '+%F %T')" --arg rid "$(cat "$IDIR/run-id" 2>/dev/null || true)" \
     '{ts:$ts, run_id:$rid, criterion:$c, argv:$argv, cwd:$cwd} + (if $to == "" then {} else {timeout:($to|tonumber)} end)')" \
    && printf '%s\n' "$line" >> "$CHECKS" \
    || { echo "❌ не зміг записати перевірку" >&2; return 1; }
  REPLACED="$replaced"
}

case "$ACTION" in
  list)
    if [ -s "$CHECKS" ]; then
      echo "Перевірки цієї задачі ($(count)/$MAX_CHECKS):"
      jq -r '"  • \(.criterion)\(if .timeout then "  (до \(.timeout) с)" else "" end)\n      \(.argv | map(tostring) | join(" "))"' "$CHECKS" 2>/dev/null
    else
      echo "Перевірок цієї задачі ще немає."
    fi
    if f="$(set_aside_file)"; then
      echo "Відкладені з попередньої задачі (повернути: --restore \"назва\" або --restore-all):"
      jq -r '"  • \(.criterion)"' "$f" 2>/dev/null
    fi
    ;;
  remove)
    [ -f "$CHECKS" ] && jq -e --arg c "$NAME" 'select(.criterion == $c)' "$CHECKS" >/dev/null 2>&1 \
      || { echo "❌ перевірки «${NAME}» немає (add-check --list)" >&2; exit 2; }
    keep_where '.criterion != $c' --arg c "$NAME" || { echo "❌ не зміг прибрати перевірку" >&2; exit 1; }
    echo "прибрав перевірку «${NAME}» — вона більше не виконуватиметься"
    ;;
  restore|restore-all)
    f="$(set_aside_file)" || { echo "❌ відкладених перевірок немає" >&2; exit 2; }
    if [ "$ACTION" = restore ]; then
      jq -e --arg c "$NAME" 'select(.criterion == $c)' "$f" >/dev/null 2>&1 \
        || { echo "❌ серед відкладених немає «${NAME}» (add-check --list)" >&2; exit 2; }
      sel='select(.criterion == $c)'
    else
      sel='.'
    fi
    n=0
    while IFS= read -r one; do
      [ -n "$one" ] || continue
      write_check "$(jq -r '.criterion' <<<"$one")" "$(jq -c '.argv' <<<"$one")" \
                  "$(jq -r '.cwd // ""' <<<"$one")" "$(jq -r '.timeout // ""' <<<"$one")" || exit $?
      n=$((n + 1))
    done < <(jq -c --arg c "$NAME" "$sel" "$f" 2>/dev/null)
    echo "повернув $n перевірк(у/и) з попередньої задачі — рушій виконає їх сам"
    ;;
  add)
    CRIT="${1:-}"
    [ -n "$CRIT" ] || { usage; exit 2; }
    shift
    [ "${1:-}" = "--" ] || { echo "❌ після критерію потрібен -- і команда: add-check \"…\" -- ./scripts/ui-check.sh" >&2; exit 2; }
    shift
    [ "$#" -gt 0 ] || { echo "❌ нема команди — перевірка це команда, а не твердження" >&2; exit 2; }
    # One JSON string per argument, whatever it holds. Splitting on newlines turned `bash -c "<script>"`
    # into `bash -c "<first line>"`, and a check that ran nothing came back as a pass.
    argv_json="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "$@")" \
      || { echo "❌ не зміг записати перевірку" >&2; exit 1; }
    REPLACED=""
    write_check "$CRIT" "$argv_json" "$PWD" "$TIMEOUT" || exit $?
    to_note=""; [ -n "$TIMEOUT" ] && to_note=" (до $TIMEOUT с)"
    if [ -n "$REPLACED" ]; then
      echo "замінив перевірку «$(printf '%s' "$REPLACED" | head -1)» на «${CRIT}»$to_note — рушій виконає її сам і занесе результат у evidence.json"
    else
      echo "записав перевірку «${CRIT}»$to_note — рушій виконає її сам і занесе результат у evidence.json"
    fi
    ;;
esac
