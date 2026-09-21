#!/bin/bash
# Talking to a run is not the same as asking it for more work.
#
# The director read a finished report and asked «but why exactly like that?». The message went into the live
# session, and the session's own delivery step deleted `done`, `outcome.json` and `stalled.json` —
# so accepted work silently re-opened, went through review a second time, and his question looked
# like a re-run. Words must leave a finished run finished; only a request for more work re-opens
# it, and then as a REVISION with its own identity and its own report.
set -u
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
. "$BIN_DIR/supervisor-lib.sh"

IDIR="$SUP_INSTANCES/probe"; mkdir -p "$IDIR"
printf 'passed\n' > "$IDIR/done"
printf '{"result":"succeeded_changes","summary":"перший результат"}\n' > "$IDIR/outcome.json"
printf '{"id":"D-FIRST","at":"2026-08-16T09:00:00Z","task":"перша робота","report_key":"aaaa1111"}\n' > "$IDIR/dispatch.json"

echo "===== a revision is recorded without erasing what came before ====="

directive="$(open_revision "$IDIR" "перевір ще й на iPad")"

new_id="$(jq -r '.id' "$IDIR/dispatch.json")"
[ "$new_id" != "D-FIRST" ] && ok "the revision has its own identity" || bad "the revision reused the first job's id"
[ -f "$IDIR/dispatches/$new_id.json" ] && ok "it is written to the journal, once" || bad "no journal record for the revision"
[ "$(jq -r '.report_key' "$IDIR/dispatch.json")" != "aaaa1111" ] \
  && ok "it owes its OWN report" || bad "the revision would overwrite the first report"
[ "$(jq -r '.revision' "$IDIR/dispatch.json")" = "true" ] && ok "it says it is a revision" || bad "nothing marks it as a revision"
case "$directive" in
  *"reports/$(jq -r '.report_key' "$IDIR/dispatch.json")"*) ok "the worker is asked for that report" ;;
  *) bad "the revision was opened without asking for a report" ;;
esac
# The whole point: opening a revision does not touch the previous result.
[ -f "$IDIR/outcome.json" ] && ok "the previous outcome is untouched" || bad "opening a revision erased the previous outcome"
[ -f "$IDIR/dispatches/D-FIRST.json" ] || printf '{"id":"D-FIRST"}' > "$IDIR/dispatches/D-FIRST.json"

echo
echo "===== the two intents exist, and words are the default ====="
grep -q 'MODE="conversation"' "$BIN_DIR/worker-send.sh" \
  && ok "conversation is what a message means unless stated otherwise" \
  || bad "the default intent is not conversation"
if grep -q 'if \[ "\$MODE" = "continue" \]; then' "$BIN_DIR/worker-send.sh" \
   && ! grep -q '^       rm -f "\$SUP_INSTANCES/\$slug/done"' "$BIN_DIR/worker-send.sh"; then
  ok "terminal markers are cleared only when more work was asked for"
else
  bad "a plain message still clears the run's completion markers"
fi

echo
[ "$fails" = 0 ] && echo "✅ a question is not a re-run" || echo "❌ $fails problem(s)"
exit "$fails"
