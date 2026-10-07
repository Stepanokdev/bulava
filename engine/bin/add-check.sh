#!/bin/bash
set -u
SELF="${BASH_SOURCE[0]}"; while [ -L "$SELF" ]; do d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac; done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"; . "$BIN_DIR/supervisor-lib.sh"

CRIT="${1:-}"
[ -n "$CRIT" ] || { echo "usage: add-check \"<criterion>\" -- <command> [args...]" >&2; exit 2; }
shift
[ "${1:-}" = "--" ] || { echo "❌ після критерію потрібен -- і команда: add-check \"…\" -- ./scripts/ui-check.sh" >&2; exit 2; }
shift
[ "$#" -gt 0 ] || { echo "❌ нема команди — перевірка це команда, а не твердження" >&2; exit 2; }

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
# The same words again REPLACE the check registered under them. A command can be wrong — quoting
# that a shell reads differently than its author did, a URL with a typo — and the file is the run's
# control state, which nothing else may edit. With append-only and a cap of ten, a broken check
# stood in the evidence for good, failing a run that had done the work. Replacing it keeps the cap
# meaningful and leaves exactly one command on record per claim, the one that will be run.
replaced=0
if [ -f "$CHECKS" ] && jq -e --arg c "$CRIT" 'select(.criterion == $c)' "$CHECKS" >/dev/null 2>&1; then
  jq -c --arg c "$CRIT" 'select(.criterion != $c)' "$CHECKS" > "$CHECKS.tmp.$$" 2>/dev/null \
    && mv -f "$CHECKS.tmp.$$" "$CHECKS" \
    || { rm -f "$CHECKS.tmp.$$"; echo "❌ не зміг замінити попередню перевірку" >&2; exit 1; }
  replaced=1
fi
if [ -f "$CHECKS" ] && [ "$(grep -c . "$CHECKS" 2>/dev/null || echo 0)" -ge 10 ]; then
  echo "❌ вже 10 перевірок — більше не додаю. Об'єднай їх в одну команду." >&2; exit 2
fi

argv_json="$(printf '%s\n' "$@" | jq -R . | jq -sc .)"
jq -nc --arg c "$CRIT" --argjson argv "$argv_json" --arg cwd "$PWD" \
       --arg ts "$(date '+%F %T')" --arg rid "$(cat "$IDIR/run-id" 2>/dev/null || true)" \
   '{ts:$ts, run_id:$rid, criterion:$c, argv:$argv, cwd:$cwd}' >> "$CHECKS" \
  || { echo "❌ не зміг записати перевірку" >&2; exit 1; }

if [ "$replaced" = 1 ]; then
  echo "замінив перевірку «${CRIT}» новою командою — рушій виконає її сам і занесе результат у evidence.json"
else
  echo "записав перевірку «${CRIT}» — рушій виконає її сам і занесе результат у evidence.json"
fi
