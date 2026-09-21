#!/bin/bash
set -u
SELF="${BASH_SOURCE[0]}"; while [ -L "$SELF" ]; do d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac; done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"; . "$BIN_DIR/supervisor-lib.sh"

RESULT="${1:?usage: worker-outcome.sh <result> [summary]}"; shift; SUMMARY="$*"
outcome_valid "$RESULT" || { echo "❌ invalid result '$RESULT' — expected one of: $OUTCOME_RESULTS" >&2; exit 2; }

scope="$(worker_scope "$PWD")"
if [ "${scope%%:*}" != instance ]; then
  # A hand-run from an ordinary shell owes nobody a result and exits quietly. A WORKER carrying a
  # token that names no live run is the case this protocol exists for: its declaration went
  # nowhere, and an exit 0 would tell it the run is settled when the run is still waiting.
  if [ -n "${ORCHESTRATOR_RUN_ID:-}" ]; then
    echo "❌ outcome NOT recorded — run $ORCHESTRATOR_RUN_ID no longer exists (nothing was written)" >&2
    exit 1
  fi
  echo "not in a supervised run — outcome not recorded" >&2; exit 0
fi
IDIR="$(instance_dir "${scope#instance:}")"
run_still_ours "$IDIR" || {
  echo "❌ outcome NOT recorded — the run changed between lookup and write" >&2; exit 1
}
# The repository this run is ABOUT. It used to be read off $PWD, which was the same thing only for
# as long as a worker never left the project folder — and the receipt then described whichever
# repository, or state folder, the worker happened to be standing in.
PROJ_DIR="$(run_project_dir "$IDIR" "$PWD")"
rid="$(cat "$IDIR/run-id" 2>/dev/null || true)"
sid="$(cat "$IDIR/session-id" 2>/dev/null || true)"
# WHICH piece of work this result is about. Without it a marker left by one dispatch reads as the
# verdict on the next, and nothing downstream can tell "this task has a result" from "some task
# once did".
did="$(jq -r '.id // empty' "$IDIR/dispatch.json" 2>/dev/null || true)"
tid="$(thread_get "$IDIR" '.thread_id')"

tmp="$IDIR/outcome.json.tmp.$$"
if jq -nc --arg r "$RESULT" --arg s "$SUMMARY" --arg ts "$(date '+%F %T')" \
      --arg rid "$rid" --arg sid "$sid" --arg cwd "$PWD" --arg did "$did" --arg tid "$tid" \
      '{schema:1, result:$r, summary:$s, ts:$ts, run_id:$rid, session_id:$sid, cwd:$cwd}
       + (if $did == "" then {} else {dispatch_id:$did} end)
       + (if $tid == "" then {} else {thread_id:$tid} end)' > "$tmp" 2>/dev/null \
   && mv -f "$tmp" "$IDIR/outcome.json"; then
  :
else
  rm -f "$tmp" 2>/dev/null || true
  echo "❌ could not write outcome.json" >&2; exit 1
fi

# Settled, not closed. "Commit it and cut a release" after a success is the same task asking for
# its next step, and an answer to needs_input is the director replying rather than starting over —
# so a result only earns the NEXT message the right to be asked which it is.
thread_settle "$IDIR" "$RESULT" "$did"

case "$RESULT" in
  blocked|needs_input|failed) printf '%s\n' "$(outcome_to_done "$RESULT")" > "$IDIR/done" ;;
esac

write_receipt() {
  command -v python3 >/dev/null 2>&1 || return 0
  local rdir="$IDIR/report"; mkdir -p "$rdir" 2>/dev/null || return 0
  local branch head base range commits diffstat findings task unblock f
  branch="$(git -C "$PROJ_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  base="$(read_base_sha "$IDIR")"
  commits='[]'; diffstat=""
  if [ -n "$base" ] && git -C "$PROJ_DIR" cat-file -e "$base" 2>/dev/null; then
    range="$base..HEAD"
    commits="$(git -C "$PROJ_DIR" log "$range" --pretty=format:'%h%x1f%s' 2>/dev/null \
      | jq -R -s 'split("\n")|map(select(length>0))|map(split("\u001f"))|map({sha:.[0],subject:.[1]})' 2>/dev/null || echo '[]')"
    diffstat="$(git -C "$PROJ_DIR" diff --stat "$range" 2>/dev/null | tail -1)"
  fi
  [ -z "$diffstat" ] && diffstat="$(git -C "$PROJ_DIR" diff --stat 2>/dev/null | tail -1)"

  findings="$(findings_json "$IDIR" "$rid")"

  unblock=""
  for f in "$IDIR/last-decision.json" "$IDIR/ask-user.json"; do
    [ -f "$f" ] || continue
    unblock="$(jq -r '.unblock_action // .default_action // ""' "$f" 2>/dev/null || true)"
    [ -n "$unblock" ] && break
  done

  task=""
  for f in "$IDIR/task" "$IDIR/task.md" "$IDIR/mission.md"; do
    [ -f "$f" ] && { task="$(cat "$f" 2>/dev/null)"; break; }
  done

  local review=""
  case "$RESULT" in
    succeeded_changes) review="pending" ;;
  esac

  local lang="${SUPERVISOR_REPORT_LANGUAGE:-Ukrainian}"

  jq -nc --arg r "$RESULT" --arg s "$SUMMARY" --arg ts "$(date '+%F %T')" \
        --arg rid "$rid" --arg br "$branch" --arg pn "$(basename "$PROJ_DIR")" \
        --arg ds "$diffstat" --arg ub "$unblock" --arg tk "$task" --arg rv "$review" \
        --arg lg "$lang" \
        --argjson cm "$commits" --argjson fd "$findings" \
        '{result:$r, summary:$s, ts:$ts, run_id:$rid, branch:$br, project_name:$pn,
          diffstat:$ds, unblock:$ub, task:$tk, review:$rv, language:$lg,
          commits:$cm, findings:$fd}' \
    > "$rdir/receipt.json" 2>/dev/null || true
  python3 "$BIN_DIR/receipt-render.py" "$rdir/report.html" < "$rdir/receipt.json" >/dev/null 2>&1 || true
}
write_receipt

echo "✅ outcome recorded: $RESULT"
