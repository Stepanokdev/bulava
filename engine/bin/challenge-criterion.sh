#!/bin/bash
set -u
SELF="${BASH_SOURCE[0]}"; while [ -L "$SELF" ]; do d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac; done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"; . "$BIN_DIR/supervisor-lib.sh"

ID="${1:?usage: challenge-criterion.sh <AC-id> <reason> <replacement|-> [evidence...]}"; shift
REASON="${1:?reason: impossible_precondition | contradicts_base | wrong_mode | already_covered}"; shift
REPLACEMENT="${1:?replacement (one line), or - for none}"; shift
EVIDENCE="$*"

case "$REASON" in
  impossible_precondition|contradicts_base|wrong_mode|already_covered) ;;
  *) echo "❌ невідома причина '$REASON' (impossible_precondition | contradicts_base | wrong_mode | already_covered)" >&2; exit 2 ;;
esac

# Same as add-check: the run is a property of the process, not of the folder it stands in.
scope="$(worker_scope "$PWD")"
if [ "${scope%%:*}" = instance ]; then
  IDIR="$(instance_dir "${scope#instance:}")"
elif [ ! -d "${IDIR:-}" ]; then
  if [ -n "${ORCHESTRATOR_RUN_ID:-}" ]; then
    echo "❌ оскарження НЕ записано — прогін $ORCHESTRATOR_RUN_ID більше не існує" >&2; exit 1
  fi
  slug="$(slug_for "$PWD")"; IDIR="$(instance_dir "$slug")"
fi
[ -d "$IDIR" ] || { echo "❌ нема теки прогону — запусти через night-shift" >&2; exit 1; }

RID="$(cat "$IDIR/run-id" 2>/dev/null || true)"
if ! runspec_acceptance "$IDIR" | grep -q "^$ID	"; then
  echo "❌ у цьому RunSpec немає критерію '$ID'. Наявні:" >&2
  runspec_acceptance "$IDIR" | sed 's/^/   /' >&2
  exit 2
fi

[ -n "$EVIDENCE" ] || { echo "❌ без доказу оскарження не приймається — вкажи файл:рядок на БАЗОВОМУ коміті" >&2; exit 2; }

jq -nc --arg id "$ID" --arg r "$REASON" --arg rep "$REPLACEMENT" --arg ev "$EVIDENCE" \
       --arg ts "$(date '+%F %T')" --arg rid "$RID" --arg cwd "$PWD" \
   '{ts:$ts, run_id:$rid, criterion:$id, reason:$r, replacement:(if $rep == "-" then null else $rep end),
     evidence:$ev, cwd:$cwd, state:"proposed"}' >> "$IDIR/challenges.jsonl" 2>/dev/null \
  || { echo "❌ не зміг записати оскарження" >&2; exit 1; }

echo "recorded challenge to $ID ($REASON) — рев'ю вирішить; критерій лишається чинним, поки воно не вирішило"
