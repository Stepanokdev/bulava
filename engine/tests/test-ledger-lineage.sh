#!/bin/bash
# The record has to survive being rebuilt: which event, in what order, continuing what.
#
# Ordering was solved by a fractional clock, and corruption by an atomic append. Neither answers
# the question the record actually exists for — what happened to THIS piece of work across the
# transitions it goes through. A revision opened a new dispatch id with no link back, so the new
# work and the work it revised read as two unrelated jobs; there was no id for an event itself,
# so nothing could reference one; and with no sequence, a missing event was invisible.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$TMP/state"
. "$ROOT/bin/supervisor-lib.sh"
LEDGER="$TMP/state/decisions.jsonl"

IDIR="$TMP/state/instances/demo"; mkdir -p "$IDIR"
printf 'run-aaa\n' > "$IDIR/run-id"
printf 'sess-111\n' > "$IDIR/claude-session-id"
jq -nc '{id:"disp-1", at:"now", task:"first ask", report_key:"aa11"}' > "$IDIR/dispatch.json"

echo "===== every event is identifiable and placeable ====="
journal_event "$IDIR" started "first"
journal_event "$IDIR" nudge   "second"
journal_event "$IDIR" answer  "third"
jq -e 'has("event_id") and (.event_id | length > 8)' "$LEDGER" >/dev/null 2>&1 \
  && ok "each event has an id of its own" || bad "no event_id: $(head -1 "$LEDGER")"
n=$(jq -r '.event_id' "$LEDGER" | sort -u | wc -l | tr -d ' ')
[ "$n" = 3 ] && ok "and the ids are distinct" || bad "only $n distinct ids for 3 events"
seqs="$(jq -r '.seq' "$LEDGER" | tr '\n' ' ')"
[ "$seqs" = "1 2 3 " ] && ok "the sequence is monotonic, so a gap would be visible" \
  || bad "sequence is $seqs"
jq -e '.provider_session == "sess-111"' "$LEDGER" >/dev/null 2>&1 \
  && ok "each event names the provider session that produced it" || bad "no provider session"
jq -e '.run_id == "run-aaa" and .dispatch_id == "disp-1"' "$LEDGER" >/dev/null 2>&1 \
  && ok "and the run and dispatch it belongs to" || bad "identity lost"

echo "===== a revision says what it continues ====="
open_revision "$IDIR" "more work please" >/dev/null 2>&1
jq -e '.parent_dispatch_id == "disp-1"' "$IDIR/dispatch.json" >/dev/null 2>&1 \
  && ok "the new dispatch links back to the one it revises" \
  || bad "no parent link: $(cat "$IDIR/dispatch.json")"
jq -e '.attempt == 2' "$IDIR/dispatch.json" >/dev/null 2>&1 \
  && ok "and counts as the second attempt" || bad "attempt not counted"
new_did="$(jq -r '.id' "$IDIR/dispatch.json")"
[ "$new_did" != "disp-1" ] && ok "while keeping its own identity" || bad "reused the old dispatch id"

journal_event "$IDIR" outcome "after the revision"
last="$(tail -1 "$LEDGER")"
printf '%s' "$last" | jq -e '.parent_dispatch_id == "disp-1" and .attempt == 2' >/dev/null 2>&1 \
  && ok "events after it carry the lineage too" || bad "lineage missing from later events: $last"

echo "===== the chain can actually be walked ====="
# The whole point: from the newest event, reach the original dispatch without guessing.
chain="$(jq -r 'select(.dispatch_id != "") | "\(.dispatch_id)<-\(.parent_dispatch_id // "root")"' "$LEDGER" | tail -1)"
case "$chain" in *"<-disp-1") ok "the newest event names its ancestor ($chain)" ;;
  *) bad "cannot walk back: $chain" ;; esac
# And a resume — a new provider session on the same dispatch — stays attributable.
printf 'sess-222\n' > "$IDIR/claude-session-id"
journal_event "$IDIR" resumed "same work, new session"
sessions="$(jq -r 'select(.dispatch_id == "'"$new_did"'") | .provider_session' "$LEDGER" | sort -u | tr '\n' ' ')"
case "$sessions" in *sess-111*sess-222*|*sess-222*sess-111*)
    ok "one dispatch across two provider sessions is reconstructable" ;;
  *) bad "resume is not reconstructable: $sessions" ;; esac

echo "===== a run with no instance dir still records, without inventing lineage ====="
journal_event - orphan "no run behind it"
last="$(grep '"kind":"orphan"' "$LEDGER" | tail -1)"
printf '%s' "$last" | jq -e 'has("event_id")' >/dev/null 2>&1 \
  && ok "it still has an event id" || bad "no id for an instance-less event"
printf '%s' "$last" | jq -e 'has("seq") | not' >/dev/null 2>&1 \
  && ok "and claims no sequence it cannot have" || bad "invented a sequence: $last"
printf '%s' "$last" | jq -e 'has("parent_dispatch_id") | not' >/dev/null 2>&1 \
  && ok "and no parentage" || bad "invented parentage"

echo "===== concurrency: two writers in one run cannot take the same number ====="
w() { for i in $(seq 1 25); do journal_event "$IDIR" tick "w$1-$i"; done; }
: > "$LEDGER"; printf '0\n' > "$IDIR/seq"
( w A ) & ( w B ) & wait
total=$(wc -l < "$LEDGER" | tr -d ' ')
uniq_seq=$(jq -r '.seq // "none"' "$LEDGER" | sort -u | wc -l | tr -d ' ')
[ "$total" = 50 ] && ok "every event was written (50)" || bad "wrote $total"
[ "$uniq_seq" = "$total" ] && ok "and every one got its own number" \
  || bad "$uniq_seq distinct numbers for $total events — the counter races"

echo
if [ "$fails" -eq 0 ]; then echo "✅ the record can be rebuilt across revision and resume"; else echo "❌ $fails problem(s)"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
