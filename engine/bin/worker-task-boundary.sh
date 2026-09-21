#!/bin/bash
# The worker's own say over where one task ends and the next begins.
#
# The engine decides this structurally, when a message is accepted: while a task is open, the next
# message is the next step of it. That is right nearly always and it is what stops a one-line
# correction from being researched from scratch — but "nearly always" is not "always", and the
# implementer is the one who has actually read both the message and the code.
#
#   task-boundary new "what the new task is"   the message in hand is separate work; everything
#                                              downstream — the Codex brief, the review, the
#                                              report — follows the new objective instead of
#                                              staying quietly attached to the old one.
#   task-boundary continue                     the opposite: a message the engine treated as a
#                                              fresh task is really the next step of the last one.
#
# It changes what the ENGINE believes. It does not change what the director asked for.
set -u
SELF="${BASH_SOURCE[0]}"; while [ -L "$SELF" ]; do d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac; done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"; . "$BIN_DIR/supervisor-lib.sh"

WANT="${1:-}"; shift 2>/dev/null || true; WHY="$*"
case "$WANT" in
  new|continue) ;;
  *) echo 'usage: task-boundary new "what the new task is" | task-boundary continue' >&2; exit 2 ;;
esac

scope="$(worker_scope "$PWD")"
if [ "${scope%%:*}" != instance ]; then
  if [ -n "${ORCHESTRATOR_RUN_ID:-}" ]; then
    echo "❌ task boundary UNCHANGED — run $ORCHESTRATOR_RUN_ID no longer exists" >&2; exit 1
  fi
  echo "not in a supervised run — task boundary unchanged" >&2; exit 0
fi
IDIR="$(instance_dir "${scope#instance:}")"
run_still_ours "$IDIR" || { echo "❌ task boundary UNCHANGED — the run changed under it" >&2; exit 1; }

if [ "$WANT" = new ] && [ -z "$WHY" ]; then
  echo 'task-boundary new needs one line saying what the new task is.' >&2; exit 2
fi

thread_boundary "$IDIR" "$WANT" "$WHY" || { echo "could not change the task boundary" >&2; exit 1; }
journal_event "$IDIR" task-boundary "$WANT: $(printf '%s' "$WHY" | head -c 160)" '{"source":"worker"}'
echo "$(date '+%F %T') [task-boundary] $WANT — $(printf '%s' "$WHY" | head -c 120)" >> "$SUP_STATE/supervisor.log"

case "$WANT" in
  new)      echo "Межу задачі оновлено: далі це нова задача — «$(printf '%s' "$WHY" | head -c 120)»." ;;
  continue) echo "Межу задачі оновлено: це продовження поточної задачі." ;;
esac
exit 0
