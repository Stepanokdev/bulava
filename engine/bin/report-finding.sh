#!/bin/bash
set -u
SELF="${BASH_SOURCE[0]}"; while [ -L "$SELF" ]; do d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac; done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"; . "$BIN_DIR/supervisor-lib.sh"
CLASS="${1:?usage: report-finding.sh <class> <text>}"; shift; TEXT="$*"
scope="$(worker_scope "$PWD")"
if [ "${scope%%:*}" != instance ]; then
  # Two different situations used to wear the same words and the same quiet exit 0. A developer
  # running this by hand is not in a run and never was — nothing is owed. A WORKER whose token
  # names a run that is gone is the dangerous one: its finding went nowhere, and reading that as
  # success is how a blocker ends up recorded only in prose nothing reads.
  if [ -n "${ORCHESTRATOR_RUN_ID:-}" ]; then
    echo "❌ finding NOT recorded — run $ORCHESTRATOR_RUN_ID no longer exists (nothing was written)" >&2
    exit 1
  fi
  echo "not in a supervised run — finding not recorded" >&2; exit 0
fi
IDIR="$(instance_dir "${scope#instance:}")"
RID="$(cat "$IDIR/run-id" 2>/dev/null || true)"   # stamp the run so the gate can honor only FRESH findings
run_still_ours "$IDIR" || {
  echo "❌ finding NOT recorded — the run changed between lookup and write" >&2; exit 1
}
# A failed append used to be swallowed by `|| true`, which printed "recorded finding" over a file
# that had not been written.
if ! jq -nc --arg c "$CLASS" --arg t "$TEXT" --arg ts "$(date '+%F %T')" --arg cwd "$PWD" --arg rid "$RID" \
     '{ts:$ts, class:$c, text:$t, cwd:$cwd, run_id:$rid}' >> "$IDIR/findings.jsonl"; then
  echo "❌ could not write the finding to $IDIR/findings.jsonl" >&2; exit 1
fi
echo "recorded finding [$CLASS]"
