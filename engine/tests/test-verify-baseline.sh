#!/bin/bash
# The verifier's shell-suite step: only the tests that can see the change run, and a test that is
# red at the base commit is not this change's failure.
#
# What happened: six review rounds in one afternoon, each FAILED by this step, because two engine
# suites were red on the clean tree before the work began. The worker said so twice; nothing read
# it. And every round ran all eighty-odd scripts for a change that touched three of them.
#
# A small repository stands in for the engine: a code root with two scripts and a shared library,
# a tests dir with four tests. Asserted:
#   - a change to one script selects the tests that name it, and no others
#   - a change inside one library function selects the tests that name that function, and the
#     tests of every script that calls it
#   - a library change outside any function runs everything (nothing can be said about who is hit)
#   - a test red at base AND now is excluded, and the step passes when nothing else is red
#   - a test that turns red with the change fails the step, and the note says which
#   - nothing under the code root changed ⇒ the step is skipped, not run
#   - SUPERVISOR_TEST_SELECT=0 runs everything, as before
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SUPERVISOR_STATE_DIR="$(mktemp -d)"
. "$ROOT/bin/supervisor-lib.sh"
VERIFY="$ROOT/bin/verify.sh"
export SUPERVISOR_VERIFY_STEP_TIMEOUT=120 SUPERVISOR_VERIFY_TOTAL_TIMEOUT=300 SUPERVISOR_TEST_JOBS=2

pass=0; fail=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
no(){ echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

PROJ="$(mktemp -d)"
cleanup(){ rm -rf "$SUPERVISOR_STATE_DIR" "$PROJ"; }
trap cleanup EXIT

mkdir -p "$PROJ/engine/bin" "$PROJ/engine/tests"
cat > "$PROJ/engine/bin/alpha.sh" <<'EOF'
#!/bin/bash
echo alpha
EOF
cat > "$PROJ/engine/bin/beta.sh" <<'EOF'
#!/bin/bash
echo beta
EOF
cat > "$PROJ/engine/bin/shared-lib.sh" <<'EOF'
#!/bin/bash
greet() {
  echo "hello"
}

count() {
  echo 3
}
EOF
cat > "$PROJ/engine/tests/test-alpha.sh" <<'EOF'
#!/bin/bash
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ "$(bash "$HERE/bin/alpha.sh")" = alpha ]
EOF
cat > "$PROJ/engine/tests/test-beta.sh" <<'EOF'
#!/bin/bash
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ "$(bash "$HERE/bin/beta.sh")" = beta ]
EOF
cat > "$PROJ/engine/tests/test-greet.sh" <<'EOF'
#!/bin/bash
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/bin/shared-lib.sh"
[ "$(greet)" = hello ]
EOF
cat > "$PROJ/engine/bin/counter.sh" <<'EOF'
#!/bin/bash
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/shared-lib.sh"
count
EOF
cat > "$PROJ/engine/tests/test-counter.sh" <<'EOF'
#!/bin/bash
# Never says the function's name: it runs the script that calls it.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ "$(bash "$HERE/bin/counter.sh")" = 3 ]
EOF
cat > "$PROJ/engine/tests/test-always-red.sh" <<'EOF'
#!/bin/bash
# red before, red after: somebody else's problem
exit 1
EOF
chmod +x "$PROJ"/engine/bin/*.sh "$PROJ"/engine/tests/*.sh
( cd "$PROJ" && git init -q && git config user.email t@t && git config user.name t \
    && git add -A && git commit -qm base >/dev/null )
BASE="$(git -C "$PROJ" rev-parse HEAD)"
IDIR="$(instance_dir "$(slug_for "$PROJ")")"; mkdir -p "$IDIR"
printf '%s\n' "$(canon_path "$PROJ")" > "$IDIR/project"
printf '%s\n' "$BASE" > "$IDIR/base-sha"

ev_of(){ jq -r "$1" "$EV" 2>/dev/null; }
ran(){ ls "$(dirname "$EV")"/shell-rc-engine-tests/*.rc 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.rc$//' | sort | tr '\n' ' '; }
suite_crit(){ jq -r '.criteria[] | select(.criterion | startswith("shell suite")) | "\(.status)|\(.criterion)|\(.note)"' "$EV" 2>/dev/null; }

echo "== one script changed ⇒ only the test that names it runs =="
echo '# touched, behaviour unchanged' >> "$PROJ/engine/bin/alpha.sh"
EV="$("$VERIFY" "$PROJ" sel-1 2>/dev/null)"
check "evidence produced"                          '[ -n "$EV" ] && [ -f "$EV" ]'
check "test-alpha ran"                             'ran | grep -q test-alpha'
check "test-beta did not"                          '! ran | grep -q test-beta'
check "the always-red test did not either"         '! ran | grep -q test-always-red'
check "the step passed"                            'suite_crit | grep -q "^pass|"'
check "the note names the selection"               'suite_crit | grep -q "selected by reference to: alpha.sh"'
git -C "$PROJ" checkout -q -- engine/bin/alpha.sh

echo "== a change inside one library function ⇒ the tests naming that function =="
perl -0pi -e 's/  echo "hello"\n/  echo "hello"\n  : changed\n/' "$PROJ/engine/bin/shared-lib.sh"
EV="$("$VERIFY" "$PROJ" sel-2 2>/dev/null)"
check "test-greet ran"                             'ran | grep -q test-greet'
check "test-alpha did not"                         '! ran | grep -q test-alpha'
check "the note names the function"                'suite_crit | grep -q "shared-lib.sh{greet"'
git -C "$PROJ" checkout -q -- engine/bin/shared-lib.sh

echo "== a function reached only through another script ⇒ the test of THAT script runs =="
perl -0pi -e 's/  echo 3\n/  echo 4\n/' "$PROJ/engine/bin/shared-lib.sh"
EV="$("$VERIFY" "$PROJ" sel-2b 2>/dev/null)"
check "test-counter ran although it never names the function"  'ran | grep -q test-counter'
check "and caught the regression"                          'suite_crit | grep -q "^fail|" && suite_crit | grep -q "new failures: test-counter.sh"'
check "test-greet did not run for it"                      '! ran | grep -q test-greet'
git -C "$PROJ" checkout -q -- engine/bin/shared-lib.sh

echo "== a library change outside any function ⇒ everything runs, and the red-at-base test is excluded =="
printf '\n# a comment at the top level\nexport SOMETHING=1\n' >> "$PROJ/engine/bin/shared-lib.sh"
EV="$("$VERIFY" "$PROJ" sel-3 2>/dev/null)"
check "all five tests ran"                         '[ "$(ran | wc -w | tr -d " ")" = 5 ]'
check "the always-red test was red"                '[ "$(cat "$(dirname "$EV")/shell-rc-engine-tests/test-always-red.sh.rc")" = 1 ]'
check "…and excluded as red at base too"           'suite_crit | grep -q "red at base too, excluded: test-always-red.sh"'
check "so the step passes: no NEW failure"         'suite_crit | grep -q "^pass|shell suite: no new failures vs base"'
check "the baseline result is cached for the run, per suite"  '[ -f "$IDIR/verify-baseline/$BASE/engine-tests/test-always-red.sh.rc" ]'
check "overall evidence is pass"                   '[ "$(ev_of .overall_status)" = pass ]'
git -C "$PROJ" checkout -q -- engine/bin/shared-lib.sh

echo "== a test that turns red WITH the change fails the step =="
echo 'echo broken' > "$PROJ/engine/bin/beta.sh"
EV="$("$VERIFY" "$PROJ" sel-4 2>/dev/null)"
check "test-beta ran"                              'ran | grep -q test-beta'
check "the step failed"                            'suite_crit | grep -q "^fail|"'
check "the note names the new failure"             'suite_crit | grep -q "new failures: test-beta.sh"'
check "overall evidence is fail"                   '[ "$(ev_of .overall_status)" = fail ]'
git -C "$PROJ" checkout -q -- engine/bin/beta.sh

echo "== nothing under the code root changed ⇒ the suite is skipped =="
echo "docs" > "$PROJ/README.md"
EV="$("$VERIFY" "$PROJ" sel-5 2>/dev/null)"
check "the step is skipped"                        'suite_crit | grep -q "^skipped|"'
check "no test ran"                                '[ -z "$(ran)" ]'
rm -f "$PROJ/README.md"

echo "== a new test added by the change runs, and is not 'red at base' =="
cat > "$PROJ/engine/tests/test-new.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
EV="$("$VERIFY" "$PROJ" sel-6 2>/dev/null)"
check "the new test ran"                           'ran | grep -q test-new'
check "and the step passed"                        'suite_crit | grep -q "^pass|"'
rm -f "$PROJ/engine/tests/test-new.sh"

echo "== SUPERVISOR_TEST_SELECT=0 runs everything =="
echo '# touched again' >> "$PROJ/engine/bin/alpha.sh"
EV="$(SUPERVISOR_TEST_SELECT=0 "$VERIFY" "$PROJ" sel-7 2>/dev/null)"
check "all five tests ran"                         '[ "$(ran | wc -w | tr -d " ")" = 5 ]'
git -C "$PROJ" checkout -q -- engine/bin/alpha.sh

echo
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ] || exit 1
