#!/bin/bash
# A passed engine test is not run again on the same inputs (bin/lib/test-cache.sh), in the
# verifier's runner (bin/verify-suite-lib.sh) and in tests/run-all.sh. Pinned:
#   • the same tree twice: the second run takes the pass from the cache and says so
#   • an engine file changed: every test runs again; one test changed: only that one
#   • a failure is never kept; a tree without the engine's layout is never cached
#   • the export test's key covers every other test; SUPERVISOR_TEST_CACHE=0 turns it off
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/bin/lib/test-cache.sh"

pass=0; fail=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
no(){ echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
export SUPERVISOR_TEST_CACHE_DIR="$W/cache"
unset SUPERVISOR_TEST_CACHE
T="$W/tree"; mkdir -p "$T/engine/bin/lib" "$T/engine/tests" "$T/scripts"
cp "$ROOT/bin/lib/test-cache.sh" "$T/engine/bin/lib/"
echo '# lib' > "$T/engine/bin/supervisor-lib.sh"
echo 'echo tool' > "$T/engine/bin/tool.sh"
for n in a b; do
  printf '#!/bin/bash\necho run >> "%s/count.%s"\necho "%s ok"\n[ ! -e "%s/fail.%s" ]\n' "$W" "$n" "$n" "$W" "$n" > "$T/engine/tests/test-$n.sh"
done
count(){ grep -c . "$W/count.$1" 2>/dev/null || echo 0; }
suite(){ rm -rf "$W/rc"; printf 'engine/tests/test-a.sh\nengine/tests/test-b.sh\n' \
  | bash -c '. "$0"; run_shell_suite "$1" engine/tests "$2"' "$ROOT/bin/verify-suite-lib.sh" "$T" "$W/rc"; }

echo "===== the verifier's runner ====="
suite
check "first run: both ran and passed"            '[ "$(count a)" = 1 ] && [ "$(count b)" = 1 ] && [ "$(cat "$W/rc/test-a.sh.rc")" = 0 ]'
suite
check "same tree: neither runs again"             '[ "$(count a)" = 1 ] && [ "$(count b)" = 1 ]'
check "and the result is still a pass"            '[ "$(cat "$W/rc/test-a.sh.rc")" = 0 ] && [ "$(cat "$W/rc/test-b.sh.rc")" = 0 ]'
check "said as cached, with the old log"          'grep -q "^a ok" "$W/rc/test-a.sh.log" && grep -q "↺ cached: passed .* on these same inputs" "$W/rc/test-a.sh.log" && [ -f "$W/rc/test-a.sh.cached" ]'
echo '# one more line' >> "$T/engine/tests/test-a.sh"
suite
check "one test changed: only it runs"            '[ "$(count a)" = 2 ] && [ "$(count b)" = 1 ]'
echo 'echo tool 2' > "$T/engine/bin/tool.sh"
suite
check "the engine changed: everything runs"       '[ "$(count a)" = 3 ] && [ "$(count b)" = 2 ]'
echo 'x' > "$T/scripts/release-thing.sh"
suite
check "the scripts beside it are inputs too"      '[ "$(count a)" = 4 ] && [ "$(count b)" = 3 ]'
touch "$W/fail.b"; echo 'echo tool 3' > "$T/engine/bin/tool.sh"
suite; suite
check "a failure is never kept"                   '[ "$(count b)" = 5 ] && [ "$(cat "$W/rc/test-b.sh.rc")" != 0 ] && [ "$(count a)" = 5 ]'
rm -f "$W/fail.b"
SUPERVISOR_TEST_CACHE=0 suite
check "SUPERVISOR_TEST_CACHE=0 runs everything"   '[ "$(count a)" = 6 ] && [ "$(count b)" = 6 ]'
# A test that edits the engine while the suite runs: nothing of that run is kept.
printf '#!/bin/bash\necho run >> "%s/count.c"\necho "echo $RANDOM" > "%s/engine/bin/tool.sh"\n' "$W" "$T" > "$T/engine/tests/test-c.sh"
suite3(){ rm -rf "$W/rc"; printf 'engine/tests/test-a.sh\nengine/tests/test-c.sh\n' \
  | bash -c '. "$0"; run_shell_suite "$1" engine/tests "$2"' "$ROOT/bin/verify-suite-lib.sh" "$T" "$W/rc"; }
suite3; before_a="$(count a)"; suite3
check "the tree moved during the run: no pass kept" '[ "$(count a)" = $((before_a + 1)) ] && [ "$(count c)" = 2 ]'
rm -f "$T/engine/tests/test-c.sh"

echo "===== keys ====="
B="$(test_cache_base "$T")"
check "a base for the engine's layout"            '[ ${#B} = 40 ]'
check "none for any other tree"                   '! test_cache_base "$W/cache" >/dev/null'
mkdir -p "$W/other/tests"; cp "$T/engine/tests/test-a.sh" "$W/other/tests/"
before_o="$(count a)"
rm -rf "$W/rc"; printf 'tests/test-a.sh\n' | bash -c '. "$0"; run_shell_suite "$1" tests "$2"' "$ROOT/bin/verify-suite-lib.sh" "$W/other" "$W/rc"
printf 'tests/test-a.sh\n' | bash -c '. "$0"; run_shell_suite "$1" tests "$2"' "$ROOT/bin/verify-suite-lib.sh" "$W/other" "$W/rc"
check "another project's suite is not cached"     '[ "$(count a)" = $((before_o + 2)) ]'
cp "$T/engine/tests/test-a.sh" "$T/engine/tests/test-export-suite.sh"
k1="$(test_cache_key "$B" "$T/engine/tests/test-export-suite.sh")"
echo '# changed' >> "$T/engine/tests/test-b.sh"
k2="$(test_cache_key "$B" "$T/engine/tests/test-export-suite.sh")"
check "the export test's key covers every test"   '[ "$k1" != "$k2" ]'

echo "===== run-all.sh uses it ====="
check "run-all keeps passes and offers --no-cache" 'grep -q "test-cache.sh" "$ROOT/tests/run-all.sh" && grep -q -- "--no-cache" "$ROOT/tests/run-all.sh"'
check "and lets the switch through its scrub"     'grep -q "SUPERVISOR_TEST_CACHE|SUPERVISOR_TEST_CACHE_DIR" "$ROOT/tests/run-all.sh"'

echo
echo "test cache: $pass passed, $fail failed"
[ "$fail" = 0 ]
