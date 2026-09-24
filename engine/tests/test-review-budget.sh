#!/bin/bash
# The unit of the review's patience is a REQUEST, not a run.
#
# The gate allows one remediation before it hands the findings to the director, and it counted them
# per RUN. A durable chat is ONE run that lives for days, so the first failed review spent the only
# remediation and every FAIL after it went straight to him with Claude never being told. On
# atlas-mobile that happened twice in an evening: the haptics/accessibility findings, and then the
# report's missing video — that one for a request three minutes old which had never failed anything.
#
# The counters now reset when one of HIS messages actually lands in the session. The gate's own
# remediation is parked without a message id precisely so that a run cannot refill the budget it
# just spent by having its own instruction delivered late.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export SUPERVISOR_STATE_DIR="$TMP/state"
mkdir -p "$SUPERVISOR_STATE_DIR/instances/demo"
. "$BIN_DIR/supervisor-lib.sh"

IDIR="$SUPERVISOR_STATE_DIR/instances/demo"
echo "RUN-42" > "$IDIR/run-id"

# Exactly the four files the gate keys off $RUN_KEY.
seed()  { for f in remediations rounds rounds-meta harness; do echo 1 > "$SUPERVISOR_STATE_DIR/$f-RUN-42"; done; }
left()  { ls "$SUPERVISOR_STATE_DIR" 2>/dev/null | grep -cE '^(remediations|rounds|rounds-meta|harness)-RUN-42$'; }
want()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (треба $3, отримано $2)"; fi; }

echo "===== his request clears the run's counters ====="
seed; want "four counters seeded" "$(left)" 4
reset_review_budget "$IDIR"; want "all four cleared" "$(left)" 0

echo "===== and nothing else is touched by accident ====="
seed
reset_review_budget "$TMP/not-an-instance"; want "unknown instance dir is a no-op" "$(left)" 4
reset_review_budget ""; want "empty argument is a no-op" "$(left)" 4
mv "$IDIR/run-id" "$TMP/run-id.bak"
reset_review_budget "$IDIR" 2>"$TMP/err"; want "no run key ⇒ nothing removed" "$(left)" 4
want "and not a word on stderr" "$( [ -s "$TMP/err" ] && echo noisy || echo quiet )" quiet
echo "SESSION-9" > "$IDIR/claude-session-id"; echo 1 > "$SUPERVISOR_STATE_DIR/remediations-SESSION-9"
reset_review_budget "$IDIR"
want "falls back to the claude session id" \
     "$(ls "$SUPERVISOR_STATE_DIR" | grep -c '^remediations-SESSION-9$')" 0
want "the run-keyed counters stay untouched" "$(left)" 4
mv "$TMP/run-id.bak" "$IDIR/run-id"

echo "===== the run's wall clock restarts with his request ====="
# The gate parks a run that is still returning to review after SUPERVISOR_MAX_RUN_SECONDS. In a
# durable chat that ceiling became an expiry date on the whole conversation: his client chat hit it
# while the reviewer was still making progress, and every later message would have parked at its
# first Stop. The clock measures one request's patience, so his next request starts it over.
seed
touch -t 202401010000 "$IDIR/started-at"
old_clock="$(stat -f %m "$IDIR/started-at")"
reset_review_budget "$IDIR"
new_clock="$(stat -f %m "$IDIR/started-at")"
want "the clock is restarted, not left expired" "$( [ "$new_clock" -gt "$old_clock" ] && echo yes || echo no )" yes
want "and it now reads as a fresh run" \
     "$( [ $(( $(date +%s) - new_clock )) -lt 60 ] && echo fresh || echo stale )" fresh
want "the counters went with it" "$(left)" 0

echo "===== but nothing restarts a clock nobody asked to restart ====="
seed
touch -t 202401010000 "$IDIR/started-at"
untouched="$(stat -f %m "$IDIR/started-at")"
reset_review_budget "$TMP/not-an-instance"
want "an unknown instance leaves the clock alone" \
     "$(stat -f %m "$IDIR/started-at")" "$untouched"
want "and the counters too" "$(left)" 4

echo "===== a parked message: his resets, the gate's must not ====="
inject_task() { return 0; }          # stand in for a live tmux session
seed
jq -nc '{ts:"now", message:"🌙 Ревізія не прийняла — виправ САМЕ ці пункти"}' > "$(undelivered_file "$IDIR")"
flush_undelivered fake-session "$IDIR" >/dev/null 2>&1
want "the gate's own remediation does NOT refill the budget" "$(left)" 4
jq -nc '{ts:"now", message:"Брат, зроби ще й пошук", id:"E7A1-2B"}' > "$(undelivered_file "$IDIR")"
flush_undelivered fake-session "$IDIR" >/dev/null 2>&1
want "a parked message of HIS does reset it" "$(left)" 0

echo
[ "$fails" = 0 ] && echo "RESULT: review budget follows the request" \
                 || echo "RESULT: $fails failed"
exit $([ "$fails" = 0 ] && echo 0 || echo 1)
