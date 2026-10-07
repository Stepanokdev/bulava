#!/bin/bash
# The review loop has to be legible from outside the gate.
#
# «When a run spun for twelve hours and six review rounds, and nobody stopped it.»
#
# The gate has always counted rounds, defects and stall — into `$STATE_DIR/rounds-$RUN_KEY` and a
# log line, keyed by run id, where only the gate could read them. So from the app a run on its
# sixth round was indistinguishable from a run on its first. It now writes the same numbers into
# the RUN's folder, which is what the app polls.
#
# The function is exercised for real; the call sites and the cleanup are pinned by inspection,
# because reaching them means driving a whole Codex review.
set -u
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)/review-gate.sh"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
sed -n '/^note_progress()/,/^}/p'  "$HOOK" >  "$TMP/fn.sh"
sed -n '/^clear_progress()/,/^}/p' "$HOOK" >> "$TMP/fn.sh"
IDIR="$TMP/run"; mkdir -p "$IDIR"
run() { IDIR_SCOPE="$IDIR" bash -c ". '$TMP/fn.sh'; $*"; }
FILE="$IDIR/review-progress.json"

echo "===== a failing round records what the app needs to judge it ====="
run 'note_progress review 3 8 4 9 0 2'
if jq -e . "$FILE" >/dev/null 2>&1; then ok "valid JSON"; else bad "not valid JSON: $(cat "$FILE" 2>/dev/null)"; fi
check() {
  local expr="$1" what="$2"
  if jq -e "$expr" "$FILE" >/dev/null 2>&1; then ok "$what"; else bad "$what — got $(cat "$FILE")"; fi
}
check '.kind == "review"'    "the kind of loop is named"
check '.round == 3 and .max == 8' "the round and the budget left"
check '.findings == 4 and .prev_findings == 9' "both counts, so direction is readable"
check '.stall == 0 and .stall_limit == 2' "and how close the gate is to giving up"

echo "===== the night nudge is recorded too — it used to be silent ====="
run 'note_progress nudge 2 8'
check '.kind == "nudge" and .round == 2 and .max == 8' "a refused handoff is visible"
# Absent facts must be ABSENT, not zero: "findings: 0" reads as "nothing left to fix", which is
# the opposite of "nobody counted".
check 'has("findings") | not' "an uncounted field is omitted, never zeroed"
check 'has("stall") | not'    "the same for stall"

echo "===== a finished run keeps no counter ====="
run 'clear_progress'
if [ -f "$FILE" ]; then bad "the counter outlived the run — the card would show a stale round"
else ok "cleared"; fi

echo "===== and the gate calls it where the loop actually turns ====="
src="$(cat "$HOOK")"
case "$src" in *'note_progress review "$next" "$MAX_ROUNDS"'*)
  ok "the progressive review loop reports each round" ;;
  *) bad "the review loop no longer reports" ;; esac
case "$src" in *'note_progress nudge "$handoffs" "$MAX_ROUNDS"'*)
  ok "the night nudge reports" ;;
  *) bad "the night nudge went silent again" ;; esac
case "$src" in *'note_progress remediation'*)
  ok "a scoped run's fix iteration reports" ;;
  *) bad "the bounded remediation does not report" ;; esac
# The cleanup has to happen for EVERY terminal disposition, and before anything else a
# disposition does — so no exit path after it can skip it. Proved by running the real `mark_done`,
# not by matching its text: the text changes (it grew a reason for the director), the promise does not.
sed -n '/^mark_done()/,/^}/p'     "$HOOK" >  "$TMP/done.sh"
sed -n '/^gate_event()/,/^}/p'    "$HOOK" >> "$TMP/done.sh"
cat >> "$TMP/done.sh" <<'STUBS'
GATE_REVIEW_STAGE=gate.review
run_event() { printf '%s\t%s\t%s\n' "$2" "$3" "${4:-}" >> "$EVENTS"; }
journal_event() { :; }
work_tree_digest() { echo digest; }
restamp_receipt() { :; }
worktree_dirty() { return 1; }
resolve_base_sha() { :; }
snapshot_director_work() { :; }
untracked_manifest() { :; }
codex_decision_clear() { :; }
STUBS
finish() {  # $1 = disposition, $2 = why, $3 = 1 if a review round is open, [$4] = make the first event abort
  rm -f "$IDIR/done" "$TMP/events"
  IDIR_SCOPE="$IDIR" EVENTS="$TMP/events" DONE_FILE="$IDIR/done" STATE_DIR="$TMP" RUN_KEY=k cwd="$TMP" \
    REVIEW_STAGE_OPEN="$3" ABORT="${4:-}" bash -c '
      . "'"$TMP/fn.sh"'"; . "'"$TMP/done.sh"'"
      [ -n "$ABORT" ] && run_event() { exit 3; }
      note_progress review 2 3 1 4
      [ -f "$IDIR_SCOPE/review-progress.json" ] || { echo "no counter to clear"; exit 9; }
      mark_done "$1" "$2"' _ "$1" "$2"
}
for disp in passed debt needs-user scope_violation; do
  finish "$disp" "" 0
  if [ -f "$FILE" ]; then bad "a $disp run kept its round counter"
  elif [ "$(cat "$IDIR/done" 2>/dev/null)" != "$disp" ]; then bad "$disp: the disposition was not written"
  else ok "a $disp run clears the counter"; fi
done
# The BLOCKED verdict: parked as needs-user with the reviewer's reason, a review round still open.
finish needs-user "Codex зупинив рев'ю: потрібен доступ до production VPS" 1
if [ -f "$FILE" ]; then bad "a BLOCKED review kept its round counter"; else ok "a BLOCKED review clears the counter"; fi
if grep -q $'^gate.review\twaiting\tCodex зупинив' "$TMP/events" 2>/dev/null \
   && grep -q $'^run\tneeds-user\tCodex зупинив' "$TMP/events" 2>/dev/null; then
  ok "…closes the review step and carries the reason into the stop"
else
  bad "BLOCKED left the review step open or lost the reason: $(cat "$TMP/events" 2>/dev/null)"
fi
# First, before anything that can fail: an abort in the very first step after it still finds the
# counter gone.
finish needs-user "" 1 abort
if [ -f "$FILE" ]; then bad "the cleanup is not first — an exit after it kept the counter"
else ok "the cleanup comes before anything that can stop mark_done"; fi
# The sentinel prev_findings must never reach the app.
case "$src" in *'[ "$_prev" -ge 999999 ]'*)
  ok "the first round's sentinel is dropped, not rendered as \"was 999999\"" ;;
  *) bad "the sentinel prev_findings can reach the app" ;; esac

echo
if [ "$fails" -eq 0 ]; then echo "✅ the loop is legible from outside"; else echo "❌ $fails problem(s)"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
