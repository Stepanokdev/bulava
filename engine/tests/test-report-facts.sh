#!/bin/bash
# The report is composed from what the run actually produced — before it is composed.
#
# The prompt asked whether machine evidence and findings existed, at a point where both variables
# were still empty: they were read forty lines further down. So the writer was told "none", every
# time, and never saw the declared outcome or the reviewer's verdict at all. A report could describe
# a different run than the one that happened, which is what the director kept reading.
set -u
ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ENGINE/bin/report.sh"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

line_of() { grep -n "$1" "$SRC" | head -1 | cut -d: -f1; }

echo "===== the facts are loaded before the writer runs ====="
composed="$(line_of '^  PROMPT="You are composing')"
for what in "^FINDINGS_JSON=" "^EVIDENCE_JSON=\"null\"" "^OUTCOME_RESULT=" "^REVIEW_STATE="; do
  at="$(line_of "$what")"
  if [ -n "$at" ] && [ -n "$composed" ] && [ "$at" -lt "$composed" ]; then
    ok "$what is known before composing (line $at < $composed)"
  else
    bad "$what is read at ${at:-nowhere}, composing starts at ${composed:-?}"
  fi
done

echo
echo "===== and they reach the writer ====="
for what in 'HOW IT ENDED' 'the run.s own words' 'Findings it filed' 'Machine evidence' 'Criteria the reviewer ruled on'; do
  grep -q "$what" "$SRC" && ok "the prompt carries: $what" || bad "the prompt never mentions: $what"
done

echo
echo "===== the reader gets the result first ====="
grep -q 'FIRST block: what the result is' "$SRC" && ok "the order is stated as a rule" || bad "nothing tells the writer what to lead with"
grep -q 'A caveat is never the opening' "$SRC" && ok "and a caveat is explicitly not the opening" || bad "a caveat may still lead"

echo
echo "===== a retracted blocker is not presented as an open one ====="
grep -q 'later retracted is NOT an open blocker' "$SRC" && ok "the writer is told" || bad "a retracted blocker can still lead the report"
grep -q 'superseded one is NOT an unmet criterion' "$SRC" && ok "and a superseded criterion is not an unmet one" \
  || bad "a superseded criterion can still be reported as unmet"

echo
[ "$fails" = 0 ] && echo "✅ report: composed from what happened" || echo "❌ report: $fails problem(s)"
exit "$fails"
