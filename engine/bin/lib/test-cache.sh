#!/bin/bash
# A passed engine test is not run again on the same inputs.
#
# A release that changed only the app's version and the site (1.20.3 → 1.20.4) ran the whole engine
# suite again, nested export run included, and so did every review round of a change whose engine
# files had not moved since the last green run. A test's result is a function of what it can read:
# the engine, the scripts beside it, the app sources two of the tests grep, the test itself, and the
# tools it runs under. When all of those are byte for byte what an earlier passing run had, that pass
# stands, and the run says so: "cached", with the date and the log of the run that proved it.
#
#   . test-cache.sh
#   test_cache_base <repository root>     → digest of everything but the test scripts (compute once)
#   test_cache_key  <base> <test file>    → the key for one test
#   test_cache_hit  <key>                 → 0 when that key passed before; prints where its log is
#   test_cache_store <key> <log>          → record a pass
#
# Only passes are kept: a failure always runs again. Keys are content, not commits, so a dirty tree
# is fine and so is an exported copy with no .git. It is per machine (the tools' versions are in the
# key anyway). SUPERVISOR_TEST_CACHE=0 turns it off; SUPERVISOR_TEST_CACHE_DIR moves it.

test_cache_on() { [ "${SUPERVISOR_TEST_CACHE:-1}" = 1 ]; }
test_cache_dir() { printf '%s' "${SUPERVISOR_TEST_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/bulava-engine-tests}"; }

# Everything a test can read except the test scripts themselves. `engine/tests/test-*.sh` are left
# out so that changing one test re-runs that test, not all of them; the suite's own plumbing
# (run-all.sh, lib-*.sh, fixtures) is in, and changing it re-runs everything.
test_cache_base() {   # $1 = repository (or exported tree) root
  local top="$1"
  [ -f "$top/engine/bin/supervisor-lib.sh" ] || return 1
  {
    printf 'cache 1\n'
    uname -sr 2>/dev/null
    bash --version 2>/dev/null | head -1
    python3 --version 2>&1 | head -1
    jq --version 2>&1 | head -1
    git --version 2>&1 | head -1
    tmux -V 2>&1 | head -1
    ( cd "$top" && find engine scripts "Night Shift/Engine" -type f \
        ! -path 'engine/tests/test-*.sh' ! -name '.DS_Store' ! -path '*/__pycache__/*' ! -name '*.pyc' 2>/dev/null \
        | LC_ALL=C sort | tr '\n' '\0' | xargs -0 shasum -a 256 2>/dev/null )
  } | shasum -a 256 | cut -c1-40
}

test_cache_key() {   # $1 = base digest  $2 = test file
  local extra=""
  [ -n "${1:-}" ] && [ -f "$2" ] || return 1
  # The export test runs every other test inside a published copy: all of them are its input.
  case "$(basename "$2")" in
    test-export-suite.sh) extra="$(cat "$(dirname "$2")"/test-*.sh 2>/dev/null | shasum -a 256 | cut -c1-40)" ;;
  esac
  printf '%s %s %s %s' "$1" "$(basename "$2")" "$(shasum -a 256 < "$2" | cut -c1-64)" "$extra" | shasum -a 256 | cut -c1-40
}

test_cache_hit() {   # $1 = key → prints the cached log's path
  local d; d="$(test_cache_dir)"
  [ -n "${1:-}" ] && [ -f "$d/$1.pass" ] || return 1
  printf '%s' "$d/$1.log"
}

test_cache_store() {   # $1 = key  $2 = the passing run's log
  local d; d="$(test_cache_dir)"
  [ -n "${1:-}" ] || return 0
  mkdir -p "$d" 2>/dev/null || return 0
  cp -f "$2" "$d/$1.log.tmp.$$" 2>/dev/null && mv -f "$d/$1.log.tmp.$$" "$d/$1.log" \
    && date '+%F %T' > "$d/$1.pass"
  # Old entries go after a month; nothing reads them after the inputs moved on.
  find "$d" -type f -mtime +30 -delete 2>/dev/null || true
}

test_cache_note() {   # $1 = key → "passed <when> on these same inputs; log: <path>"
  local d; d="$(test_cache_dir)"
  printf 'cached: passed %s on these same inputs; log %s' "$(cat "$d/$1.pass" 2>/dev/null)" "$d/$1.log"
}
