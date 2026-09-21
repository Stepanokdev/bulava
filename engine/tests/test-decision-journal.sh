#!/bin/bash
# What was decided, by whom, and when.
#
# Every change we are making now moves a decision from the director to the machine: Codex answers
# questions of effort, the gate keeps a run working, a revision opens without a human. That is the
# point — and it is also how quality degrades quietly if it goes wrong. `supervisor.log` carries
# prose for a person reading it live; this carries fields for the question nobody asks until later:
# "when did it start deciding things it should have escalated?"
set -u
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
. "$BIN_DIR/supervisor-lib.sh"

IDIR="$SUP_INSTANCES/probe"; mkdir -p "$IDIR"
printf 'RUN-7\n' > "$IDIR/run-id"
printf '{"id":"D-9","task":"робота","report_key":"bbbb2222"}\n' > "$IDIR/dispatch.json"

echo "===== an event carries who, which run, and which job ====="

journal_event "$IDIR" decision "лишаємо варіант B" '{"source":"codex"}'
line="$(tail -1 "$SUP_STATE/decisions.jsonl")"
[ "$(printf '%s' "$line" | jq -r '.run_id')" = "RUN-7" ] && ok "the run is named" || bad "no run id"
[ "$(printf '%s' "$line" | jq -r '.dispatch_id')" = "D-9" ] && ok "the job is named" || bad "no dispatch id"
[ "$(printf '%s' "$line" | jq -r '.source')" = "codex" ] && ok "who decided is recorded" || bad "no source"
[ "$(printf '%s' "$line" | jq -r '.kind')" = "decision" ] && ok "the kind is recorded" || bad "no kind"

echo
echo "===== it appends, never rewrites ====="
before="$(grep -c . "$SUP_STATE/decisions.jsonl")"
journal_event "$IDIR" escalation "потрібне рішення директора" '{"source":"gate"}'
journal_event - nudge "працюй далі" '{"source":"gate"}'
after="$(grep -c . "$SUP_STATE/decisions.jsonl")"
[ "$after" = "$((before + 2))" ] && ok "both events kept ($after lines)" || bad "events were lost or merged"
[ "$(tail -2 "$SUP_STATE/decisions.jsonl" | head -1 | jq -r '.kind')" = "escalation" ] \
  && ok "order is preserved" || bad "order is not preserved"

echo
echo "===== every place that decides something writes one ====="
for pair in "review-gate.sh:terminal" "review-gate.sh:escalation" "review-gate.sh:nudge" \
            "answer-question.sh:question" "answer-question.sh:answer"; do
  f="${pair%%:*}"; kind="${pair##*:}"
  if grep -q "journal_event .* $kind" "$HOOK_DIR/$f"; then ok "$f records $kind"
  else bad "$f decides $kind and records nothing"; fi
done
grep -q "journal_event .* revision" "$BIN_DIR/supervisor-lib.sh" && ok "a revision is recorded" || bad "revisions go unrecorded"

echo
[ "$fails" = 0 ] && echo "✅ decisions leave a trail" || echo "❌ $fails problem(s)"
exit "$fails"
