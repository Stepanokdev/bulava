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
      SUPERVISOR_TEST_JOBS|SUPERVISOR_TEST_SKIP) ;;
      SUPERVISOR_*|ORCHESTRATOR_*|IDIR|BULAVA_*) scrub=(${scrub[@]+"${scrub[@]}"} -u "$_name") ;;
    esac
  done
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    case " ${SUPERVISOR_TEST_SKIP:-} " in *" $(basename "$t") "*) continue ;; esac
    [ -f "$tree/$t" ] || { echo absent > "$rcdir/$(basename "$t").rc"; continue; }
    ( cd "$tree" && env ${scrub[@]+"${scrub[@]}"} bash "$t" >"$rcdir/$(basename "$t").log" 2>&1 </dev/null; echo $? > "$rcdir/$(basename "$t").rc" ) &
    pids+=("$!")
    if [ "${#pids[@]}" -ge "$jobs" ]; then wait "${pids[0]}" 2>/dev/null; pids=("${pids[@]:1}"); fi
  done
  wait
}
