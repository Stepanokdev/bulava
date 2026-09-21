#!/bin/bash
# The ledger must not lie, and it must be orderable.
#
# `decisions.jsonl` is one append-only file that every run on the machine writes into, and it is
# what any account of what happened is reconstructed from. Two defects were found in it by
# measurement, not by reading:
#
#   * `jq >> file` writes through stdio, which flushes in 4096-byte blocks. A line longer than
#     that leaves the process in two write() calls, and a second run appending between them
#     splices its line into the middle of the first. The journal already held 5606-byte lines;
#     two concurrent writers at that size corrupted roughly a fifth of what they wrote.
#   * `ts` is whole seconds, and a run emits several events inside one second, so its own events
#     could not be put back in the order they happened.
#
# This suite reproduces the first with real concurrency rather than trusting the fix.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state"
LEDGER="$TMP/state/decisions.jsonl"

cat > "$TMP/writer.sh" <<'W'
export SUPERVISOR_STATE_DIR="$1"
. "$2/bin/supervisor-lib.sh"
# Cyrillic, because the cap is counted in characters and this text is two bytes per character —
# an ASCII-only test would pass a bound that real summaries break.
big="$(printf '%.0sдовгий текст ' $(seq 1 600))"
for i in $(seq 1 40); do
  journal_event - "kind-$3" "$big" "$(jq -nc --arg p "$big" '{payload:$p}')"
done
W

echo "===== two runs writing at once cannot splice each other's lines ====="
bash "$TMP/writer.sh" "$TMP/state" "$ROOT" A &
bash "$TMP/writer.sh" "$TMP/state" "$ROOT" B &
wait

total=$(wc -l < "$LEDGER" | tr -d ' ')
broken=0
while IFS= read -r l; do
  printf '%s' "$l" | jq -e . >/dev/null 2>&1 || broken=$((broken + 1))
done < "$LEDGER"

[ "$total" = 80 ] && ok "every event was recorded (80)" || bad "expected 80 events, got $total"
[ "$broken" = 0 ] && ok "none of them was corrupted by the other writer" \
                  || bad "$broken of $total lines are unparseable — the ledger is lying"

echo "===== an oversized event is recorded small, never dropped ====="
longest=$(awk '{ if (length($0) > m) m = length($0) } END { print m+0 }' "$LEDGER")
if [ "$longest" -lt 4096 ]; then ok "the longest line ($longest bytes) stays under the write buffer"
else bad "a $longest-byte line can still be split mid-write"; fi
if jq -e 'select(.truncated == true)' "$LEDGER" >/dev/null 2>&1; then
  ok "oversized events are marked truncated rather than silently shortened"
else bad "nothing was marked truncated — the cap did not engage on 7KB summaries"; fi
if jq -e 'select(.truncated == true) | select((.kind // "") != "" and has("run_id"))' "$LEDGER" >/dev/null 2>&1; then
  ok "a truncated event keeps its identity — that is what the ledger is for"
else bad "truncation cost the event its identity"; fi

echo "===== and the record can be put back in order ====="
if jq -e 'has("t") and (.t | type == "number")' "$LEDGER" >/dev/null 2>&1; then
  ok "every event carries a sub-second clock"
else bad "no sub-second clock — same-second events cannot be ordered"; fi
if jq -e 'has("ts") and (.ts | test("^[0-9]{4}-"))' "$LEDGER" >/dev/null 2>&1; then
  ok "the human timestamp is unchanged, so existing readers still work"
else bad "ts changed shape — this breaks every reader of the ledger"; fi
distinct=$(jq -r '.t' "$LEDGER" | sort -u | wc -l | tr -d ' ')
# Two genuinely simultaneous writers may tie; a wholesale collapse means no real resolution.
if [ "$distinct" -ge $(( total * 9 / 10 )) ]; then ok "the clock actually resolves events ($distinct/$total distinct)"
else bad "only $distinct distinct stamps for $total events — no usable ordering"; fi
if jq -e 'has("pid")' "$LEDGER" >/dev/null 2>&1; then
  ok "and names the process that wrote it, so a tie is still attributable"
else bad "no writer identity on a shared file"; fi

echo
if [ "$fails" -eq 0 ]; then echo "✅ the ledger survives concurrent runs and can be ordered"; else echo "❌ $fails problem(s)"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
