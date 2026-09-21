#!/bin/bash
# Every channel STANDARDS tells a worker to use must exist by the name it is given.
#
# `report-finding` was the one that did not. The standing instructions say to record a blocker
# through `$IDIR/report-finding` — and the launcher never created that name, so the sanctioned
# channel was unreachable by the only name anyone had for it. Findings then went into prose, where
# nothing reads them, which is exactly how a night ends with a wall nobody recorded.
set -u
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
SUP="$(cd "$(dirname "${BASH_SOURCE[0]}")/../supervisor" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

launcher="$(cat "$BIN/night-shift.sh")"
standards="$(cat "$SUP/STANDARDS.md")"

echo "===== each name the standards give a worker is installed ====="
# The name, and the script it must resolve to.
for pair in "report-outcome:worker-outcome.sh" \
            "report-finding:report-finding.sh" \
            "capture:worker-capture.sh" \
            "add-check:add-check.sh" \
            "history:history.sh"; do
  name="${pair%%:*}"; script="${pair#*:}"
  case "$launcher" in
    *"\"\$IDIR/$name\""*) : ;;
    *) bad "\$IDIR/$name is never created"; continue ;;
  esac
  case "$launcher" in
    *"$script\" \"\$IDIR/$name\""*) ok "\$IDIR/$name → $script" ;;
    *) bad "\$IDIR/$name does not point at $script" ;;
  esac
  [ -f "$BIN/$script" ] && : || bad "$script does not exist"
done

echo "===== and every name the standards mention is one of them ====="
# Anything the instructions name and the launcher does not create is a promise to a worker that
# cannot be kept.
missing=0
for name in $(printf '%s' "$standards" | grep -oE '\$IDIR/[a-z-]+' | sed 's|\$IDIR/||' | sort -u); do
  case "$name" in
    # Documents, not commands. The pattern above stops at the dot, so `decisions.md` arrives here
    # as `decisions`.
    decisions|plan|research|notes|reports|design) continue ;;
  esac
  case "$launcher" in
    *"\"\$IDIR/$name\""*) ;;
    *) bad "STANDARDS tells a worker to call \$IDIR/$name and nothing creates it"; missing=1 ;;
  esac
done
[ "$missing" = 0 ] && ok "no instruction names a channel that does not exist"

echo "===== both launch paths, not just one ====="
# The launcher has two places that build a run folder; a channel added to one of them is a channel
# that exists only for some runs.
for name in report-outcome report-finding capture history; do
  n=$(printf '%s' "$launcher" | grep -c "\"\$IDIR/$name\"" || true)
  [ "$n" -ge 2 ] && ok "$name is installed on both paths" || bad "$name appears $n time(s)"
done

echo "===== a finding actually lands, and only from a real run ====="
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$TMP/state" "$TMP/proj"
# The script finds its run from ORCHESTRATOR_RUN_ID, so the fixture has to be a real supervised
# run — an instance folder whose run-id the caller carries. (It used to resolve by WORKING
# DIRECTORY, which is why a worker reading an allowed neighbouring repository lost the channel;
# see test-worker-run-identity.sh.)
. "$BIN/supervisor-lib.sh"
PROJ="$(canon_path "$TMP/proj")"
IDIR="$(instance_dir "$(slug_for "$PROJ")")"; mkdir -p "$IDIR"
printf '%s\n' "$PROJ" > "$IDIR/project"
printf 'run-1\n' > "$IDIR/run-id"
# The channel is bound to the RUN, not merely to the folder: without a matching
# ORCHESTRATOR_RUN_ID it fails closed and records nothing. That is the correct behaviour — a
# finding from an unsupervised shell would be a finding from nobody — so the fixture is a run.
( cd "$PROJ" && ORCHESTRATOR_RUN_ID=run-1 bash "$BIN/report-finding.sh" blocker "потрібен ключ" ) >/dev/null 2>&1
if [ -s "$IDIR/findings.jsonl" ]; then ok "written to findings.jsonl"
else bad "nothing was written"; fi
jq -e 'select(.class == "blocker") | .text | test("ключ")' "$IDIR/findings.jsonl" >/dev/null 2>&1 \
  && ok "with its class and its words intact" || bad "malformed: $(cat "$IDIR/findings.jsonl" 2>/dev/null)"
jq -e '.run_id == "run-1"' "$IDIR/findings.jsonl" >/dev/null 2>&1 \
  && ok "stamped with the run, so the gate honours only fresh ones" || bad "no run stamp"
before=$(wc -l < "$IDIR/findings.jsonl" | tr -d ' ')
( cd "$PROJ" && bash "$BIN/report-finding.sh" blocker "з чужої оболонки" ) >/dev/null 2>&1
[ "$(wc -l < "$IDIR/findings.jsonl" | tr -d ' ')" = "$before" ] \
  && ok "and a shell that is not the run records nothing — fail closed" \
  || bad "an unsupervised shell wrote a finding"

echo
if [ "$fails" -eq 0 ]; then echo "✅ every documented channel exists and works"; else echo "❌ $fails problem(s)"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
