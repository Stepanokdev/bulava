#!/bin/bash
# The runner the verifier's shell-suite step uses, in a file of its own because the step runs it
# under an alarm in a fresh bash, and a function defined in verify.sh cannot be seen from there.
#
#   printf 'engine/tests/test-x.sh\n' | bash -c '. verify-suite-lib.sh; run_shell_suite <tree> <tests dir> <rc dir>'
#
# Each test's exit code lands in <rc dir>/<test>.rc (the word `absent` when the tree has no such
# file — a test added by the change does not exist at the base) and its output in <test>.log.
run_shell_suite() {   # $1 = tree to run in  $2 = tests dir (repo-relative)  $3 = rc dir ; tests on stdin (repo-relative paths)
  local tree="$1" tdir="$2" rcdir="$3" jobs t pids=()
  mkdir -p "$rcdir"
  jobs="${SUPERVISOR_TEST_JOBS:-}"
  if [ -z "$jobs" ]; then
    jobs="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
    [ "$jobs" -gt 8 ] 2>/dev/null && jobs=8
  fi
  case "$jobs" in ""|*[!0-9]*) jobs=4 ;; esac
  [ "$jobs" -lt 1 ] && jobs=1
  # The verifier runs inside the run it is verifying, and the worker environment carries that run
  # identity plus the application tuning. A test that inherits either stops measuring the code and
  # starts measuring the machine. Same scrub as tests/run-all.sh.
  local scrub=() _name
  for _name in $(env | sed "s/=.*//" | sort -u); do
    case "$_name" in
      SUPERVISOR_TEST_JOBS|SUPERVISOR_TEST_SKIP|SUPERVISOR_TEST_CACHE|SUPERVISOR_TEST_CACHE_DIR) ;;
      SUPERVISOR_*|ORCHESTRATOR_*|IDIR|BULAVA_*) scrub=(${scrub[@]+"${scrub[@]}"} -u "$_name") ;;
    esac
  done
  # The engine's own suite keeps its passes (lib/test-cache.sh): between two review rounds most of
  # the engine has not moved, and a test whose inputs are byte for byte the same passes the same.
  local cbase="" key hit
  if [ "$tdir" = engine/tests ] && [ -f "$tree/engine/bin/lib/test-cache.sh" ]; then
    . "$tree/engine/bin/lib/test-cache.sh"
    test_cache_on && cbase="$(test_cache_base "$tree")"
  fi
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    case " ${SUPERVISOR_TEST_SKIP:-} " in *" $(basename "$t") "*) continue ;; esac
    [ -f "$tree/$t" ] || { echo absent > "$rcdir/$(basename "$t").rc"; continue; }
    key=""
    if [ -n "$cbase" ]; then
      key="$(test_cache_key "$cbase" "$tree/$t")"
      if hit="$(test_cache_hit "$key")"; then
        { cat "$hit" 2>/dev/null; echo "  ↺ $(test_cache_note "$key")"; } > "$rcdir/$(basename "$t").log"
        echo 0 > "$rcdir/$(basename "$t").rc"; echo "$key" > "$rcdir/$(basename "$t").cached"
        continue
      fi
    fi
    [ -n "$key" ] && echo "$key" > "$rcdir/$(basename "$t").key"
    ( cd "$tree" && env ${scrub[@]+"${scrub[@]}"} bash "$t" >"$rcdir/$(basename "$t").log" 2>&1 </dev/null; echo $? > "$rcdir/$(basename "$t").rc" ) &
    pids+=("$!")
    if [ "${#pids[@]}" -ge "$jobs" ]; then wait "${pids[0]}" 2>/dev/null; pids=("${pids[@]:1}"); fi
  done
  wait
  # Passes are kept only if the tree is still what the keys describe: a file the worker edited while
  # the suite ran would otherwise file a pass under bytes it never ran on.
  if [ -n "$cbase" ] && [ "$(test_cache_base "$tree")" = "$cbase" ]; then
    local k
    for k in "$rcdir"/*.key; do
      [ -f "$k" ] || continue
      t="$(basename "$k" .key)"
      [ "$(cat "$rcdir/$t.rc" 2>/dev/null)" = 0 ] && test_cache_store "$(cat "$k")" "$rcdir/$t.log"
    done
  fi
  rm -f "$rcdir"/*.key 2>/dev/null
  return 0
}
