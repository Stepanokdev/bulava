#!/bin/bash
# A blocker must not outlive the thing that caused it.
#
# The worker filed "cannot verify — the button does not exist in demo mode". The director then logged
# the simulator into a real account, the work was done and verified with it — and the run still parked
# on the original wall, because a finding was append-only with no way to take one back. He read the
# same stale sentence in every summary and said, correctly, that it was nonsense.
set -u
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
IDIR="$TMP/idir"; mkdir -p "$IDIR"; RID="RUN-1"; echo "$RID" > "$IDIR/run-id"

file() { jq -nc --arg c "$1" --arg t "$2" --arg rid "$RID" \
  '{ts:"now", class:$c, text:$t, cwd:"/x", run_id:$rid}' >> "$IDIR/findings.jsonl"; }

# The gate's own rule, lifted verbatim from review-gate.sh.
last_blocker() {
  local last blk=""
  last="$(jq -rc --arg rid "$RID" 'select((.class=="blocker" or .class=="blocker_resolved") and (.run_id // "")==$rid) | [.class, .text] | @tsv' "$IDIR/findings.jsonl" 2>/dev/null | tail -1)"
  case "$last" in blocker$'\t'*) blk="${last#*$'\t'}" ;; esac
  printf '%s' "$blk"
}

echo "===== a blocker parks the run ====="
file blocker "потрібен живий Telegram-акаунт"
[ -n "$(last_blocker)" ] && ok "the run parks while the wall stands" || bad "a blocker no longer parks"

echo
echo "===== retracting it lets the run finish ====="
file blocker_resolved "акаунт надано, сценарій прогнано наживо"
[ -z "$(last_blocker)" ] && ok "the retraction clears it" || bad "the blocker outlived its cause"

echo
echo "===== and a NEW wall after the retraction parks again ====="
file blocker "TDLib не віддає лінк для цього каналу"
[ -n "$(last_blocker)" ] && ok "a fresh blocker still parks" || bad "a retraction disarmed the channel for good"

echo
echo "===== the class survives into the documents ====="
kinds="$(jq -s 'map(.class//.kind//.type//"note") | unique | join(",")' "$IDIR/findings.jsonl")"
case "$kinds" in *blocker*) ok "a blocker is reported as a blocker, not as a note" ;;
  *) bad "the class was flattened: $kinds" ;; esac

# --- the documents, not just the gate ---------------------------------------
echo
echo "===== a retracted blocker leaves the documents, its retraction stays ====="
. "$BIN_DIR/supervisor-lib.sh"
out="$(findings_json "$IDIR" "$RID")"
kinds="$(printf '%s' "$out" | jq -r 'map(.kind) | join(",")')"
case "$kinds" in
  *blocker_resolved*) ok "the retraction is still on the page" ;;
  *) bad "the retraction disappeared: $kinds" ;;
esac
# The FIRST blocker was retracted; the one filed after it still stands.
n_blockers="$(printf '%s' "$out" | jq '[.[] | select(.kind=="blocker")] | length')"
[ "$n_blockers" = 0 ] && ok "a retracted wall is not reported as standing" \
  || bad "$n_blockers blocker(s) still reported after a retraction"

echo
echo "===== findings from another run never reach this run's documents ====="
jq -nc '{ts:"now", class:"blocker", text:"чужий прогін", cwd:"/x", run_id:"RUN-OTHER"}' >> "$IDIR/findings.jsonl"
out="$(findings_json "$IDIR" "$RID")"
case "$(printf '%s' "$out" | jq -r 'map(.text) | join(" ")')" in
  *"чужий прогін"*) bad "another run's finding leaked into this report" ;;
  *) ok "only this run's findings are shown" ;;
esac

echo
[ "$fails" = 0 ] && echo "✅ blockers: retractable, and reported as what they are" || echo "❌ blockers: $fails problem(s)"
exit "$fails"
