#!/bin/bash
# A passed engine test is not run again on the same inputs (bin/lib/test-cache.sh), in the
# verifier's runner (bin/verify-suite-lib.sh) and in tests/run-all.sh. Pinned:
#   • the same tree twice: the second run takes the pass from the cache and says so
#   • an engine file changed: every test runs again; one test changed: only that one
#   • a failure is never kept; a tree without the engine's layout is never cached
#   • a skip is not a pass; a pass without its log, or an old record, runs again; `# test-cache: off`
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

echo "===== a skip, a missing log, an opt-out ====="
printf '#!/bin/bash\necho run >> "%s/count.s"\necho "  ➖ no built application here"\n' "$W" > "$T/engine/tests/test-s.sh"
suite_s(){ rm -rf "$W/rc"; printf 'engine/tests/test-s.sh\n' \
  | bash -c '. "$0"; run_shell_suite "$1" engine/tests "$2"' "$ROOT/bin/verify-suite-lib.sh" "$T" "$W/rc"; }
suite_s; suite_s
check "a test that skipped is run again, not taken as a pass" '[ "$(count s)" = 2 ]'
printf '#!/bin/bash\necho run >> "%s/count.s"\necho "  (SKIP: tmux not installed)"\n' "$W" > "$T/engine/tests/test-s.sh"
suite_s; suite_s
check "so is one that printed SKIP"                 '[ "$(count s)" = 4 ]'
printf '#!/bin/bash\n# test-cache: off — it reads the built app\necho run >> "%s/count.s"\necho ok\n' "$W" > "$T/engine/tests/test-s.sh"
suite_s; suite_s
check "a test marked test-cache: off is never cached" '[ "$(count s)" = 6 ] && ! test_cache_key "$(test_cache_base "$T")" "$T/engine/tests/test-s.sh" >/dev/null'
rm -f "$T/engine/tests/test-s.sh"
printf '#!/bin/bash\n# test-cache: reads tools/icongen "Night Shift/Design"\necho ok\n' > "$T/engine/tests/test-r.sh"
BB="$(test_cache_base "$T")"
k_abs="$(test_cache_key "$BB" "$T/engine/tests/test-r.sh")"
mkdir -p "$T/tools/icongen" "$T/Night Shift/Design"; echo v1 > "$T/tools/icongen/build.sh"
k_v1="$(test_cache_key "$BB" "$T/engine/tests/test-r.sh")"
echo v2 > "$T/Night Shift/Design/mark.svg"
k_v2="$(test_cache_key "$BB" "$T/engine/tests/test-r.sh")"
check "a declared outside input appearing changes the key" '[ "$k_abs" != "$k_v1" ]'
check "and so does a change in it (a path with a space)"  '[ "$k_v1" != "$k_v2" ]'
rm -rf "$T/engine/tests/test-r.sh" "$T/tools" "$T/Night Shift"
# One wording for a skip across the suite, or the cache cannot tell a skip from a pass.
check "no test says it skipped in other words"     '[ -z "$(grep -lE "(echo|printf).*(— skipp(ed|ing)|\\(skipped|skipped\\))" "$ROOT"/tests/test-*.sh | grep -v "/test-test-cache.sh$")" ]'
suite; before_a="$(count a)"
KA="$(test_cache_key "$(test_cache_base "$T")" "$T/engine/tests/test-a.sh")"
check "a pass records its base and commit"          'grep -qE " base [0-9a-f]{40} commit [^ ]+$" "$W/cache/$KA.pass"'
rm -f "$W/cache/$KA.log"; suite
check "a pass whose log is gone runs again"         '[ "$(count a)" = $((before_a + 1)) ]'
date '+%F %T' > "$W/cache/$KA.pass"; suite
check "an old record with only a date runs again"   '[ "$(count a)" = $((before_a + 2)) ]'
suite
check "and the fresh record is taken next time"     '[ "$(count a)" = $((before_a + 2)) ]'

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
