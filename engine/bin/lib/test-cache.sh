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
# Only passes that RAN are kept: a failure always runs again, and so does a test that skipped (its log
# says SKIP or "➖": "no built application here" exits 0 and proves nothing about the next run, where
# the application may be there). A test whose result depends on something outside the tree — a built
# app, an installed browser, a network endpoint — says so with a line `# test-cache: off` and is never
# cached. A pass is taken only with its log still there; the record names the base digest and the
# commit it ran on. Keys are content, not commits, so a dirty tree is fine and so is an exported copy
# with no .git. It is per machine (the tools' versions are in the key anyway).
# SUPERVISOR_TEST_CACHE=0 turns it off; SUPERVISOR_TEST_CACHE_DIR moves it.

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
    command -v swiftc >/dev/null 2>&1 && swiftc --version 2>&1 | head -1
    ( cd "$top" && find engine scripts "Night Shift/Engine" -type f \
        ! -path 'engine/tests/test-*.sh' ! -name '.DS_Store' ! -path '*/__pycache__/*' ! -name '*.pyc' 2>/dev/null \
        | LC_ALL=C sort | tr '\n' '\0' | xargs -0 shasum -a 256 2>/dev/null )
  } | shasum -a 256 | cut -c1-40
}

test_cache_key() {   # $1 = base digest  $2 = test file
  local extra=""
  [ -n "${1:-}" ] && [ -f "$2" ] || return 1
  # A test that reads something outside the tree opts out: no key, never cached.
  grep -qE '^#[[:space:]]*test-cache:[[:space:]]*off' "$2" 2>/dev/null && return 1
  # What a test reads outside engine/ and scripts/ it names, `# test-cache: reads <path> …` (paths
  # from the repository's top, quoted when they have spaces): their content is in its key, and so is
  # their absence, so a key changes when the app's files beside the engine appear or move.
  local top reads p
  top="$(cd "$(dirname "$2")/../.." 2>/dev/null && pwd)"
  reads="$(sed -nE 's/^#[[:space:]]*test-cache:[[:space:]]*reads[[:space:]]+(.+)$/\1/p' "$2" 2>/dev/null)"
  if [ -n "$reads" ]; then
    extra="$(printf '%s\n' "$reads" | xargs -n1 printf '%s\n' 2>/dev/null | while IFS= read -r p; do
        [ -n "$p" ] || continue
        if [ -e "$top/$p" ]; then
          printf 'reads %s\n' "$p"
          ( cd "$top" && find "$p" -type f ! -name '.DS_Store' 2>/dev/null | LC_ALL=C sort | tr '\n' '\0' | xargs -0 shasum -a 256 2>/dev/null )
        else
          printf 'absent %s\n' "$p"
        fi
      done | shasum -a 256 | cut -c1-40)"
  fi
  # The export test runs every other test inside a published copy: all of them are its input.
  case "$(basename "$2")" in
    test-export-suite.sh) extra="$extra $(cat "$(dirname "$2")"/test-*.sh 2>/dev/null | shasum -a 256 | cut -c1-40)" ;;
  esac
  printf '%s %s %s %s' "$1" "$(basename "$2")" "$(shasum -a 256 < "$2" | cut -c1-64)" "$extra" | shasum -a 256 | cut -c1-40
}

test_cache_hit() {   # $1 = key → prints the cached log's path
  local d; d="$(test_cache_dir)"
  # The record and the log it stands on, both: a pass whose log is gone is not shown as a pass.
  [ -n "${1:-}" ] && [ -s "$d/$1.pass" ] && [ -s "$d/$1.log" ] || return 1
  # …written by a store that recorded what it stood on (an older record held only a date).
  grep -qE ' base [^ ]+ commit [^ ]+$' "$d/$1.pass" 2>/dev/null || return 1
  test_cache_skipped "$d/$1.log" && return 1
  printf '%s' "$d/$1.log"
}

# The suite's one way to say a part did not run: a line with the word SKIP (capitals) or "➖". A test
# that skips says it so; the guard in test-test-cache.sh refuses other wordings in a test's output.
test_cache_skipped() {   # $1 = a log → 0 when the test skipped (some or all of it) rather than ran
  grep -qE '(^|[^A-Za-z])SKIP([^A-Za-z]|$)|➖' "$1" 2>/dev/null
}

test_cache_store() {   # $1 = key  $2 = the passing run's log  [$3 = base digest  $4 = tree root]
  local d rev; d="$(test_cache_dir)"
  [ -n "${1:-}" ] && [ -s "${2:-}" ] || return 0
  test_cache_skipped "$2" && return 0   # a skip is not a pass
  mkdir -p "$d" 2>/dev/null || return 0
  rev="$(git -C "${4:-.}" rev-parse HEAD 2>/dev/null || echo none)"
  cp -f "$2" "$d/$1.log.tmp.$$" 2>/dev/null && mv -f "$d/$1.log.tmp.$$" "$d/$1.log" \
    && printf '%s base %s commit %s\n' "$(date '+%F %T')" "${3:-?}" "$rev" > "$d/$1.pass.tmp.$$" \
    && mv -f "$d/$1.pass.tmp.$$" "$d/$1.pass"
  # Old entries go after a month; nothing reads them after the inputs moved on.
  find "$d" -type f -mtime +30 -delete 2>/dev/null || true
}

test_cache_note() {   # $1 = key → "passed <when> on these same inputs; log: <path>"
  local d; d="$(test_cache_dir)"
  printf 'cached: passed %s on these same inputs; log %s' "$(head -1 "$d/$1.pass" 2>/dev/null)" "$d/$1.log"
}
