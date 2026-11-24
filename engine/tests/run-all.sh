#!/bin/bash
# Single entry point for the engine test suite. Runs every tests/test-*.sh and exits
# non-zero if any fails. (verify.sh's shell fallback also runs these when the engine
# dir itself is verified; this is the documented manual runner.)
#
# Run side by side, because the set has to FINISH.
#
# Sequentially this takes about a quarter of an hour — the export test alone runs the whole suite a
# second time, out of a freshly published tree — and the verifier's per-step ceiling is ten minutes.
# So the one thing a reviewer needs from a test suite, a collected pass or fail for all of it, was
# the one thing it could not give: every run came back as a timeout, whatever the code did.
#
# Every test already builds its own state directory and, where it needs one, its own HOME, so this
# is a scheduling change and not a change to what anything asserts. Output is buffered per test and
# printed in the usual order, so the log reads exactly as it did before.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

JOBS="${SUPERVISOR_TEST_JOBS:-}"
if [ -z "$JOBS" ]; then
  JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
  [ "$JOBS" -gt 8 ] 2>/dev/null && JOBS=8
fi
case "$JOBS" in ''|*[!0-9]*) JOBS=4 ;; esac
[ "$JOBS" -lt 1 ] && JOBS=1

# The export test runs this whole suite again inside a published tree. Starting it first gives it
# the longest runway, and it is told to use fewer workers so the two layers do not fight for the
# machine.
# Suites a nested run must leave alone. `test-export-suite.sh` copies the tree and runs THIS script
# inside the copy, so anything that drives a single shared resource ends up running twice at once —
# and test-web-video.sh both drives Chrome and asserts that no Chrome is left running. The nested
# copy skips it; the outer run still covers it, on the same files.
SKIP="${SUPERVISOR_TEST_SKIP:-}"
skipped() {
  case " $SKIP " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}


# The suite must not inherit the run that is running it.
#
# A worker's environment carries the live run's identity (`ORCHESTRATOR_RUN_ID`, `IDIR`) and some
# seventy `SUPERVISOR_*` overrides the application passes down. Tests assert against the DOCUMENTED
# defaults and build their own state directory, so inheriting either makes the result depend on who
# pressed the button: `test-report-finding.sh` recorded a finding into the live run instead of
# refusing outside one, and three suites read a usage guard the machine had tuned. So every test is
# started with the engine's own variables removed — except the one that belongs to this runner.
SCRUB=()
while IFS='=' read -r _name _rest; do
  case "$_name" in
    SUPERVISOR_TEST_JOBS|SUPERVISOR_TEST_SKIP|SUPERVISOR_TEST_CACHE|SUPERVISOR_TEST_CACHE_DIR) ;;
    SUPERVISOR_*|ORCHESTRATOR_*|IDIR|BULAVA_*)
      SCRUB=(${SCRUB[@]+"${SCRUB[@]}"} -u "$_name") ;;
  esac
done <<EOF_ENV
$(env | sed 's/=.*//' | sort -u)
EOF_ENV
# A test that passed on exactly these inputs is not run again (../bin/lib/test-cache.sh): its old log
# is printed with a line saying so. `--no-cache` (or SUPERVISOR_TEST_CACHE=0) runs everything.
for _a in "$@"; do [ "$_a" = --no-cache ] && export SUPERVISOR_TEST_CACHE=0; done
. ../bin/lib/test-cache.sh
CACHE_BASE=""
test_cache_on && CACHE_BASE="$(test_cache_base "$(cd ../.. && pwd)")"
run_test() {   # $1 = test file
  local key="" hit tmp rc
  if [ -n "$CACHE_BASE" ]; then
    key="$(test_cache_key "$CACHE_BASE" "$1")"
    if hit="$(test_cache_hit "$key")"; then
      cat "$hit" 2>/dev/null
      echo "  ↺ $(test_cache_note "$key")"
      return 0
    fi
  fi
  tmp="$(mktemp)"
  env ${SCRUB[@]+"${SCRUB[@]}"} bash "$1" > "$tmp" 2>&1; rc=$?
  cat "$tmp"
  # Kept only once the whole run is over and its inputs are still what they were at the start
  # (cache_commit): a file edited while the suite ran would otherwise file a pass under a key
  # that describes other bytes.
  if [ "$rc" = 0 ] && [ -n "$key" ]; then cp "$tmp" "$PENDING/$key.log"; fi
  rm -f "$tmp"
  return "$rc"
}
PENDING="$(mktemp -d)"
cache_commit() {
  local f
  [ -n "$CACHE_BASE" ] || return 0
  if [ "$(test_cache_base "$(cd ../.. && pwd)")" = "$CACHE_BASE" ]; then
    for f in "$PENDING"/*.log; do [ -f "$f" ] && test_cache_store "$(basename "$f" .log)" "$f" "$CACHE_BASE" "$(cd ../.. && pwd)"; done
  else
    echo "↺ the engine changed while the suite ran — none of this run's passes are kept"
  fi
  rm -rf "$PENDING"
}

ORDER=""
[ -f test-export-suite.sh ] && ! skipped test-export-suite.sh && ORDER="test-export-suite.sh"
for t in test-*.sh; do
  [ "$t" = "test-export-suite.sh" ] && continue
  skipped "$t" && continue
  ORDER="$ORDER $t"
done

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT" "${PENDING:-}"' EXIT

if [ "$JOBS" = 1 ]; then
  rc=0
  for t in $ORDER; do
    echo "===== $t ====="
    if run_test "$t"; then :; else rc=1; echo "  ^^ FAILED: $t"; fi
    echo
  done
  cache_commit
  [ "$rc" = 0 ] && echo "✅ ALL SUITES PASSED" || echo "❌ SOME SUITES FAILED"
  exit $rc
fi

inner_jobs=$(( JOBS / 2 )); [ "$inner_jobs" -lt 1 ] && inner_jobs=1

# bash 3.2 ships on macOS and has no `wait -n`, so the pool waits on the OLDEST job rather than the
# first to finish. It keeps roughly $JOBS in flight, which is all this needs.
pids=()
for t in $ORDER; do
  if [ "$t" = "test-export-suite.sh" ]; then
    ( SUPERVISOR_TEST_JOBS="$inner_jobs" run_test "$t" > "$OUT/$t.log" 2>&1; echo $? > "$OUT/$t.rc" ) &
  else
    ( run_test "$t" > "$OUT/$t.log" 2>&1; echo $? > "$OUT/$t.rc" ) &
  fi
  pids=(${pids[@]+"${pids[@]}"} "$!")
  if [ "${#pids[@]}" -ge "$JOBS" ]; then
    wait "${pids[0]}" 2>/dev/null
    pids=(${pids[@]:1})
  fi
done
wait

rc=0; cached=0
for t in $ORDER; do
  echo "===== $t ====="
  cat "$OUT/$t.log" 2>/dev/null
  grep -q '^  ↺ cached: ' "$OUT/$t.log" 2>/dev/null && cached=$((cached + 1))
  if [ "$(cat "$OUT/$t.rc" 2>/dev/null || echo 1)" != 0 ]; then
    rc=1; echo "  ^^ FAILED: $t"
  fi
  echo
done
cache_commit
[ "$cached" -gt 0 ] && echo "↺ $cached suite(s) taken from the cache: they passed before on these same inputs (--no-cache runs them)"
[ "$rc" = 0 ] && echo "✅ ALL SUITES PASSED" || echo "❌ SOME SUITES FAILED"
exit $rc
